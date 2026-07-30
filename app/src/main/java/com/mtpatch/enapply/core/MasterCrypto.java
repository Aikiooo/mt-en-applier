package com.mtpatch.enapply.core;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * MasterData crypto, ported from decrypt_masterdata.py / inject_layout_preserve.py.
 * AES-256-CBC + PKCS7; key/IV stored in global-metadata.dat with each byte +0x7F.
 */
public final class MasterCrypto {

    private MasterCrypto() {}

    /** CryptoKey.ToAsciiValue: each stored byte minus 0x7F. */
    public static byte[] decodeCryptoKey(byte[] raw) {
        byte[] out = new byte[raw.length];
        for (int i = 0; i < raw.length; i++) out[i] = (byte) ((raw[i] - 0x7F) & 0xFF);
        return out;
    }

    /** Extract key(32)/iv(16) at the given offsets of global-metadata.dat. */
    public static byte[][] extractKeys(byte[] metadata, int keyOff, int ivOff) {
        if (metadata == null || metadata.length < keyOff + 32 || keyOff < 0
                || metadata.length < ivOff + 16 || ivOff < 0) {
            throw new IllegalArgumentException("metadata too small for offsets");
        }
        byte[] keyRaw = new byte[32];
        byte[] ivRaw = new byte[16];
        System.arraycopy(metadata, keyOff, keyRaw, 0, 32);
        System.arraycopy(metadata, ivOff, ivRaw, 0, 16);
        return new byte[][]{decodeCryptoKey(keyRaw), decodeCryptoKey(ivRaw)};
    }

    public static byte[] decrypt(byte[] ct, byte[] key, byte[] iv) throws Exception {
        Cipher c = Cipher.getInstance("AES/CBC/PKCS5Padding");
        c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new IvParameterSpec(iv));
        return c.doFinal(ct);
    }

    /** Decrypt without unpadding (for sanity checks on possibly-unpadded data). */
    public static byte[] decryptRaw(byte[] ct, byte[] key, byte[] iv) throws Exception {
        Cipher c = Cipher.getInstance("AES/CBC/NoPadding");
        c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new IvParameterSpec(iv));
        return c.doFinal(ct);
    }

    /** True if these keys decrypt the sample CT to something that looks like a table. */
    public static boolean validate(byte[] key, byte[] iv, byte[] sampleCt) {
        try {
            byte[] pt = decryptRaw(sampleCt, key, iv);
            String head = new String(pt, 0, Math.min(pt.length, 256), StandardCharsets.UTF_8);
            return head.startsWith("id\t") || head.contains("\t");
        } catch (Throwable t) {
            return false;
        }
    }

    /** inject_layout_preserve.to_plain: LF-only, ensure trailing \n. */
    public static byte[] toPlain(String text) {
        byte[] data = text.replace("\r\n", "\n").replace("\r", "\n")
                .getBytes(StandardCharsets.UTF_8);
        if (data.length == 0 || data[data.length - 1] != '\n') {
            byte[] out = new byte[data.length + 1];
            System.arraycopy(data, 0, out, 0, data.length);
            out[data.length] = '\n';
            data = out;
        }
        return data;
    }

    /**
     * inject_layout_preserve.encrypt_fit: encrypt text so the ciphertext is EXACTLY
     * targetCt bytes (pad plaintext with '\n' so PKCS7 lands on target). Null if impossible.
     */
    public static byte[] encryptFit(byte[] plain, byte[] key, byte[] iv, int targetCt) {
        int maxP = targetCt - 1, minP = targetCt - 16;
        if (plain.length > maxP) return null;
        byte[] p = plain;
        while (p.length < minP) p = appendLf(p);
        while (true) {
            int ctLen = ((p.length / 16) + 1) * 16;
            if (ctLen == targetCt) break;
            if (ctLen > targetCt || p.length >= maxP) return null;
            p = appendLf(p);
        }
        try {
            Cipher c = Cipher.getInstance("AES/CBC/PKCS5Padding");
            c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new IvParameterSpec(iv));
            byte[] ct = c.doFinal(p);
            return ct.length == targetCt ? ct : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static byte[] appendLf(byte[] in) {
        byte[] out = new byte[in.length + 1];
        System.arraycopy(in, 0, out, 0, in.length);
        out[in.length] = '\n';
        return out;
    }

    public static int leInt(byte[] b, int off) {
        return ByteBuffer.wrap(b, off, 4).order(ByteOrder.LITTLE_ENDIAN).getInt();
    }

    public static String md5Hex(byte[] data) {
        try {
            byte[] d = MessageDigest.getInstance("MD5").digest(data);
            StringBuilder sb = new StringBuilder(32);
            for (byte x : d) sb.append(Character.forDigit((x >> 4) & 0xF, 16))
                    .append(Character.forDigit(x & 0xF, 16));
            return sb.toString();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}

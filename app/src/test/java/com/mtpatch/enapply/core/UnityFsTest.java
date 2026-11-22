package com.mtpatch.enapply.core;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;
import org.tukaani.xz.LZMA2Options;
import org.tukaani.xz.LZMAOutputStream;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Random;

import net.jpountz.lz4.LZ4Factory;

public class UnityFsTest {

    private static void putInt(ByteArrayOutputStream w, int v) {
        w.write((v >>> 24) & 0xFF);
        w.write((v >>> 16) & 0xFF);
        w.write((v >>> 8) & 0xFF);
        w.write(v & 0xFF);
    }

    private static void putShort(ByteArrayOutputStream w, int v) {
        w.write((v >>> 8) & 0xFF);
        w.write(v & 0xFF);
    }

    private static void putLong(ByteArrayOutputStream w, long v) {
        for (int i = 7; i >= 0; i--) w.write((int) (v >>> (8 * i)) & 0xFF);
    }

    private static byte[] unityLzmaCompress(byte[] raw) throws IOException {
        LZMA2Options opts = new LZMA2Options(3);
        opts.setDictSize(1 << 16);
        ByteArrayOutputStream payload = new ByteArrayOutputStream();
        int props;
        try (LZMAOutputStream out = new LZMAOutputStream(payload, opts, true)) {
            props = out.getProps();
            out.write(raw);
        }
        int dict = opts.getDictSize();
        ByteArrayOutputStream res = new ByteArrayOutputStream(5 + payload.size());
        res.write(props & 0xFF);
        res.write(dict & 0xFF);
        res.write((dict >>> 8) & 0xFF);
        res.write((dict >>> 16) & 0xFF);
        res.write((dict >>> 24) & 0xFF);
        res.write(payload.toByteArray());
        return res.toByteArray();
    }

    private static byte[] lz4Compress(byte[] raw) {
        return LZ4Factory.fastestJavaInstance().highCompressor(9).compress(raw);
    }

    private static byte[] buildSyntheticBundle(int ver, String uv, String gen, int hdrFlags,
                                               byte[][] rawBlocks, int[] blockFlags) throws IOException {
        byte[][] compBlocks = new byte[rawBlocks.length][];
        for (int i = 0; i < rawBlocks.length; i++) {
            int comp = blockFlags[i] & 0x3F;
            if (comp == 0) compBlocks[i] = rawBlocks[i];
            else if (comp == 1) compBlocks[i] = unityLzmaCompress(rawBlocks[i]);
            else if (comp == 2 || comp == 3) compBlocks[i] = lz4Compress(rawBlocks[i]);
            else throw new IllegalArgumentException("unsupported " + comp);
        }

        // Build blocksInfo: 16-byte guid + blocks + 1 node covering full stream
        ByteArrayOutputStream bi = new ByteArrayOutputStream();
        for (int i = 0; i < 16; i++) bi.write(i);
        putInt(bi, rawBlocks.length);
        long totalStream = 0;
        for (int i = 0; i < rawBlocks.length; i++) {
            putInt(bi, rawBlocks[i].length);
            putInt(bi, compBlocks[i].length);
            putShort(bi, blockFlags[i]);
            totalStream += rawBlocks[i].length;
        }
        putInt(bi, 1); // 1 node
        putLong(bi, 0);
        putLong(bi, totalStream);
        putInt(bi, 4);
        byte[] nodeName = "CAB-test".getBytes(StandardCharsets.UTF_8);
        bi.write(nodeName, 0, nodeName.length);
        bi.write(0);

        byte[] biRaw = bi.toByteArray();
        int biComp = hdrFlags & 0x3F;
        byte[] biC;
        if (biComp == 0) biC = biRaw;
        else if (biComp == 1) biC = unityLzmaCompress(biRaw);
        else if (biComp == 2 || biComp == 3) biC = lz4Compress(biRaw);
        else throw new IllegalArgumentException("unsupported biComp " + biComp);

        ByteArrayOutputStream w = new ByteArrayOutputStream();
        w.write("UnityFS\0".getBytes(StandardCharsets.US_ASCII));
        putInt(w, ver);
        w.write(uv.getBytes(StandardCharsets.UTF_8));
        w.write(0);
        w.write(gen.getBytes(StandardCharsets.UTF_8));
        w.write(0);
        int sizePos = w.size();
        putLong(w, 0);
        putInt(w, biC.length);
        putInt(w, biRaw.length);
        putInt(w, hdrFlags);

        if (ver >= 7) {
            int pad = (16 - (w.size() % 16)) % 16;
            for (int i = 0; i < pad; i++) w.write(0);
        }
        if ((hdrFlags & 0x80) == 0) {
            w.write(biC);
            if ((hdrFlags & 0x200) != 0) {
                int pad2 = (16 - (w.size() % 16)) % 16;
                for (int i = 0; i < pad2; i++) w.write(0);
            }
            for (byte[] cb : compBlocks) w.write(cb);
        } else {
            if ((hdrFlags & 0x200) != 0) {
                int pad2 = (16 - (w.size() % 16)) % 16;
                for (int i = 0; i < pad2; i++) w.write(0);
            }
            for (byte[] cb : compBlocks) w.write(cb);
            w.write(biC);
        }

        byte[] out = w.toByteArray();
        long total = out.length;
        for (int i = 0; i < 8; i++) out[sizePos + i] = (byte) (total >>> (8 * (7 - i)));
        return out;
    }

    @Test
    public void rebuildModifiedLzmaBlockUpdatesFlagToLz4Hc() throws Exception {
        // Original block 0 has pseudo-random bytes so its LZMA compressed size is large.
        byte[] orig0 = new byte[4096];
        new Random(42).nextBytes(orig0);
        // Unchanged block 1 is also LZMA to verify unchanged blocks preserve flag 1.
        byte[] orig1 = new byte[1024];
        Arrays.fill(orig1, (byte) 'B');

        byte[] bundleBytes = buildSyntheticBundle(
                8, "5.x.x", "2021.3.1f1", 0x43,
                new byte[][]{orig0, orig1},
                new int[]{0x41, 0x41}); // flag 0x40 (streamed) | 1 (LZMA)

        UnityFs.Bundle fs = UnityFs.open(bundleBytes);
        assertEquals(1, fs.blocks[0].flags & 0x3F);
        assertEquals(1, fs.blocks[1].flags & 0x3F);

        // Replace block 0 with highly compressible data so LZ4-HC easily fits <= orig b.c.
        byte[] mod0 = new byte[4096];
        Arrays.fill(mod0, (byte) 'Z');
        System.arraycopy(mod0, 0, fs.full, 0, mod0.length);
        UnityFs.reslice(fs);

        byte[] rebuilt = UnityFs.rebuild(fs);
        UnityFs.Bundle reopened = UnityFs.open(rebuilt);

        // Modified LZMA block must now carry compression flag 3 (LZ4HC) while preserving upper bits (0x40).
        assertEquals(0x43, reopened.blocks[0].flags);
        // Unchanged LZMA block keeps its original LZMA flag.
        assertEquals(0x41, reopened.blocks[1].flags);
        assertArrayEquals(mod0, reopened.decBlocks[0]);
        assertArrayEquals(orig1, reopened.decBlocks[1]);
    }

    @Test
    public void rebuildLzmaBlocksInfoConvertsToLz4Hc() throws Exception {
        byte[] block = "Hello UnityFS blocksInfo LZMA!".getBytes(StandardCharsets.UTF_8);
        byte[] bundleBytes = buildSyntheticBundle(
                8, "5.x.x", "2021.3.1f1", 0x41, // blocksInfo compressed with LZMA (flag 1)
                new byte[][]{block},
                new int[]{0x03});

        UnityFs.Bundle fs = UnityFs.open(bundleBytes);
        assertEquals(1, fs.hdr.flags & 0x3F);
        assertArrayEquals(block, fs.full);

        byte[] rebuilt = UnityFs.rebuild(fs);
        UnityFs.Bundle reopened = UnityFs.open(rebuilt);
        assertEquals(3, reopened.hdr.flags & 0x3F);
        assertEquals(0x43, reopened.hdr.flags);
        assertArrayEquals(block, reopened.full);
    }

    @Test
    public void readHeaderAndRebuildAlignVer7WithBlocksInfoAtEnd() throws Exception {
        // Choose version strings so header end before padding is NOT 16-byte aligned:
        // "UnityFS\0"(8) + ver(4) + "5.x.x\0"(6) + "2021.3.1f1\0"(11) + 20 = 49 bytes (49 % 16 == 1)
        byte[] block = "Aligned payload for ver >= 7 with 0x80 flag and no 0x200".getBytes(StandardCharsets.UTF_8);
        int flags = 0x43 | 0x80; // BlocksInfoAtTheEnd (0x80), NO 0x200 padding flag
        byte[] bundleBytes = buildSyntheticBundle(
                8, "5.x.x", "2021.3.1f1", flags,
                new byte[][]{block},
                new int[]{0x03});

        UnityFs.Header h = UnityFs.readHeader(bundleBytes);
        assertEquals(0, h.dataStart % 16);
        assertEquals(64, h.dataStart);

        UnityFs.Bundle fs = UnityFs.open(bundleBytes);
        assertArrayEquals(block, fs.full);

        // Mutate payload and rebuild to verify rebuild writes the same alignment.
        byte[] mod = "Mutated payload for ver >= 7 with 0x80 flag and no 0x200".getBytes(StandardCharsets.UTF_8);
        assertEquals(block.length, mod.length);
        System.arraycopy(mod, 0, fs.full, 0, mod.length);
        UnityFs.reslice(fs);

        byte[] rebuilt = UnityFs.rebuild(fs);
        UnityFs.Header rh = UnityFs.readHeader(rebuilt);
        assertEquals(0, rh.dataStart % 16);
        UnityFs.Bundle reopened = UnityFs.open(rebuilt);
        assertArrayEquals(mod, reopened.full);
        assertTrue((reopened.hdr.flags & 0x80) != 0);
    }
}

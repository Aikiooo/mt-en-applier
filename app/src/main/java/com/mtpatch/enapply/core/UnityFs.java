package com.mtpatch.enapply.core;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

import net.jpountz.lz4.LZ4Compressor;
import net.jpountz.lz4.LZ4Factory;
import net.jpountz.lz4.LZ4FastDecompressor;

/**
 * UnityFS (signature "UnityFS", ver 8) parse + layout-preserving rebuild.
 * Direct port of inject_layout_preserve.py + build_full_en.rebuild_hybrid:
 * unchanged blocks keep their original compressed bytes; changed blocks are
 * recompressed LZ4-HC (levels 12/9/6/3, smallest that fits the original
 * compressed size) or stored uncompressed (file grows, block table rewritten).
 */
public final class UnityFs {

    public static final class Header {
        int ver; String uv; String gen; long size;
        int ciSize; int uiSize; int flags;
        int blocksInfoAt; int dataStart;
    }

    public static final class Block {
        int u, c, flags;
        int fileOff; // where this block's payload sits in the original file
    }

    public static final class Node {
        long offset, size; int status; String name;
    }

    public static final class Bundle {
        Header hdr;
        byte[] guid;
        Block[] blocks;
        Node[] nodes;
        byte[][] decBlocks; // decompressed payload per block
        byte[] full;        // concatenation of decBlocks (patched in place)
        byte[] orig;        // original file bytes
    }

    private UnityFs() {}

    // -- big-endian helpers -------------------------------------------------
    private static int beInt(byte[] b, int o) {
        return ((b[o] & 0xFF) << 24) | ((b[o + 1] & 0xFF) << 16)
                | ((b[o + 2] & 0xFF) << 8) | (b[o + 3] & 0xFF);
    }

    private static long beLong(byte[] b, int o) {
        return ((long) beInt(b, o) << 32) | (beInt(b, o + 4) & 0xFFFFFFFFL);
    }

    private static int beShort(byte[] b, int o) {
        return ((b[o] & 0xFF) << 8) | (b[o + 1] & 0xFF);
    }

    private static void putInt(ByteArrayOutputStream w, int v) {
        w.write((v >>> 24) & 0xFF); w.write((v >>> 16) & 0xFF);
        w.write((v >>> 8) & 0xFF); w.write(v & 0xFF);
    }

    private static void putShort(ByteArrayOutputStream w, int v) {
        w.write((v >>> 8) & 0xFF); w.write(v & 0xFF);
    }

    private static void putLong(ByteArrayOutputStream w, long v) {
        for (int i = 7; i >= 0; i--) w.write((int) (v >>> (8 * i)) & 0xFF);
    }

    private static int cstrEnd(byte[] b, int o) {
        int i = o;
        while (i < b.length && b[i] != 0) i++;
        return i;
    }

    static Header readHeader(byte[] data) {
        Header h = new Header();
        if (data.length < 8 || data[0] != 'U' || data[1] != 'n' || data[2] != 'i'
                || data[3] != 't' || data[4] != 'y' || data[5] != 'F' || data[6] != 'S')
            throw new IllegalArgumentException("not a UnityFS file");
        int i = 8;
        h.ver = beInt(data, i); i += 4;
        int e = cstrEnd(data, i);
        h.uv = new String(data, i, e - i, StandardCharsets.UTF_8); i = e + 1;
        e = cstrEnd(data, i);
        h.gen = new String(data, i, e - i, StandardCharsets.UTF_8); i = e + 1;
        h.size = beLong(data, i); i += 8;
        h.ciSize = beInt(data, i); i += 4;
        h.uiSize = beInt(data, i); i += 4;
        h.flags = beInt(data, i); i += 4;
        int padn = (16 - (i % 16)) % 16;
        if ((h.flags & 0x80) != 0) {
            h.blocksInfoAt = data.length - h.ciSize;
            h.dataStart = i;
        } else {
            h.blocksInfoAt = i + padn;
            h.dataStart = h.blocksInfoAt + h.ciSize;
        }
        if ((h.flags & 0x200) != 0) { // BlockInfoNeedPaddingAtStart
            h.dataStart += (16 - (h.dataStart % 16)) % 16;
        }
        return h;
    }

    private static byte[] decompressBlock(byte[] chunk, int off, int len, int uSize, int fl) {
        int comp = fl & 0x3F;
        if (comp == 0) {
            byte[] out = new byte[len];
            System.arraycopy(chunk, off, out, 0, len);
            return out;
        }
        if (comp == 2 || comp == 3) {
            LZ4FastDecompressor d = LZ4Factory.fastestInstance().fastDecompressor();
            byte[] out = new byte[uSize];
            d.decompress(chunk, off, out, 0, uSize);
            return out;
        }
        throw new IllegalArgumentException("block compression " + comp + " unsupported");
    }

    /** parse_blocks_info: guid(16) + blocks + nodes from the (decompressed) blocks-info. */
    private static void parseBlocksInfo(byte[] raw, Bundle fs) {
        fs.guid = new byte[16];
        System.arraycopy(raw, 0, fs.guid, 0, 16);
        int j = 16;
        int bc = beInt(raw, j); j += 4;
        fs.blocks = new Block[bc];
        for (int i = 0; i < bc; i++) {
            Block b = new Block();
            b.u = beInt(raw, j); j += 4;
            b.c = beInt(raw, j); j += 4;
            b.flags = beShort(raw, j); j += 2;
            fs.blocks[i] = b;
        }
        int nc = beInt(raw, j); j += 4;
        fs.nodes = new Node[nc];
        for (int i = 0; i < nc; i++) {
            Node n = new Node();
            n.offset = beLong(raw, j); j += 8;
            n.size = beLong(raw, j); j += 8;
            n.status = beInt(raw, j); j += 4;
            int e = cstrEnd(raw, j);
            n.name = new String(raw, j, e - j, StandardCharsets.UTF_8);
            j = e + 1;
            fs.nodes[i] = n;
        }
    }

    private static byte[] buildBlocksInfo(byte[] guid, Block[] blocks, Node[] nodes) {
        ByteArrayOutputStream w = new ByteArrayOutputStream();
        w.write(guid, 0, 16);
        putInt(w, blocks.length);
        for (Block b : blocks) { putInt(w, b.u); putInt(w, b.c); putShort(w, b.flags); }
        putInt(w, nodes.length);
        for (Node n : nodes) {
            putLong(w, n.offset); putLong(w, n.size); putInt(w, n.status);
            byte[] nm = n.name.getBytes(StandardCharsets.UTF_8);
            w.write(nm, 0, nm.length); w.write(0);
        }
        return w.toByteArray();
    }

    /** open_unityfs: header, blocks-info, decompress every block, concat. */
    public static Bundle open(byte[] data) {
        Bundle fs = new Bundle();
        fs.orig = data;
        fs.hdr = readHeader(data);
        int comp = fs.hdr.flags & 0x3F;
        byte[] biRaw;
        if (comp == 2 || comp == 3) {
            biRaw = decompressBlock(data, fs.hdr.blocksInfoAt, fs.hdr.ciSize, fs.hdr.uiSize, comp);
        } else if (comp == 0) {
            biRaw = new byte[fs.hdr.ciSize];
            System.arraycopy(data, fs.hdr.blocksInfoAt, biRaw, 0, fs.hdr.ciSize);
        } else {
            throw new IllegalArgumentException("blocks-info compression " + comp);
        }
        parseBlocksInfo(biRaw, fs);
        fs.decBlocks = new byte[fs.blocks.length][];
        int pos = fs.hdr.dataStart;
        ByteArrayOutputStream full = new ByteArrayOutputStream();
        for (int i = 0; i < fs.blocks.length; i++) {
            Block b = fs.blocks[i];
            b.fileOff = pos;
            fs.decBlocks[i] = decompressBlock(data, pos, b.c, b.u, b.flags);
            if (fs.decBlocks[i].length != b.u)
                throw new IllegalStateException("block " + i + " u mismatch");
            full.write(fs.decBlocks[i], 0, fs.decBlocks[i].length);
            pos += b.c;
        }
        fs.full = full.toByteArray();
        return fs;
    }

    private static byte[] lz4Hc(byte[] raw, int level) {
        LZ4Compressor c = LZ4Factory.fastestInstance().highCompressor(level);
        return c.compress(raw);
    }

    /** build_full_en.rebuild_hybrid: see class javadoc. */
    public static byte[] rebuild(Bundle fs) {
        Header hdr = fs.hdr;
        byte[] orig = fs.orig;
        Block[] newBlocks = new Block[fs.blocks.length];
        List<byte[]> payloads = new ArrayList<>();
        for (int i = 0; i < fs.blocks.length; i++) {
            Block b = fs.blocks[i];
            byte[] dec = fs.decBlocks[i];
            byte[] origChunk = new byte[b.c];
            System.arraycopy(orig, b.fileOff, origChunk, 0, b.c);
            byte[] origDec = decompressBlock(origChunk, 0, b.c, b.u, b.flags);
            Block nb = new Block();
            nb.u = b.u; nb.flags = b.flags;
            if (java.util.Arrays.equals(dec, origDec)) {
                nb.c = b.c;
                payloads.add(origChunk);
            } else if ((b.flags & 0x3F) == 0) {
                nb.c = dec.length; // == u
                payloads.add(dec);
            } else {
                byte[] best = null;
                for (int level : new int[]{12, 9, 6, 3}) {
                    try {
                        byte[] c = lz4Hc(dec, level);
                        if (best == null || c.length < best.length) best = c;
                    } catch (Throwable ignored) {}
                }
                if (best != null && best.length <= b.c) {
                    nb.c = best.length;
                    payloads.add(best);
                } else {
                    // store uncompressed; block table rewritten, file grows
                    nb.c = dec.length;
                    nb.flags = b.flags & ~0x3F;
                    payloads.add(dec);
                }
            }
            newBlocks[i] = nb;
        }
        byte[] biRaw = buildBlocksInfo(fs.guid, newBlocks, fs.nodes);
        int biFlag = hdr.flags & 0x3F;
        byte[] biC;
        if (biFlag == 2 || biFlag == 3) biC = lz4Hc(biRaw, 9);
        else if (biFlag == 0) biC = biRaw;
        else throw new IllegalStateException("bi flag " + biFlag);

        ByteArrayOutputStream w = new ByteArrayOutputStream();
        byte[] sig = "UnityFS\0".getBytes(StandardCharsets.US_ASCII);
        w.write(sig, 0, sig.length);
        putInt(w, hdr.ver);
        byte[] uv = hdr.uv.getBytes(StandardCharsets.UTF_8);
        w.write(uv, 0, uv.length); w.write(0);
        byte[] gen = hdr.gen.getBytes(StandardCharsets.UTF_8);
        w.write(gen, 0, gen.length); w.write(0);
        int sizePos = w.size();
        putLong(w, 0);
        putInt(w, biC.length);
        putInt(w, biRaw.length);
        putInt(w, hdr.flags);
        if ((hdr.flags & 0x80) == 0) {
            int padn = (16 - (w.size() % 16)) % 16;
            for (int i = 0; i < padn; i++) w.write(0);
            w.write(biC, 0, biC.length);
            if ((hdr.flags & 0x200) != 0) {
                int padn2 = (16 - (w.size() % 16)) % 16;
                for (int i = 0; i < padn2; i++) w.write(0);
            }
            for (byte[] p : payloads) w.write(p, 0, p.length);
        } else {
            if ((hdr.flags & 0x200) != 0) {
                int padn2 = (16 - (w.size() % 16)) % 16;
                for (int i = 0; i < padn2; i++) w.write(0);
            }
            for (byte[] p : payloads) w.write(p, 0, p.length);
            w.write(biC, 0, biC.length);
        }
        byte[] out = w.toByteArray();
        long total = out.length;
        for (int i = 0; i < 8; i++) out[sizePos + i] = (byte) (total >>> (8 * (7 - i)));
        return out;
    }

    /** Re-slice fs.full into decBlocks using the original u sizes (after patching). */
    public static void reslice(Bundle fs) {
        int pos = 0;
        for (int i = 0; i < fs.blocks.length; i++) {
            int u = fs.blocks[i].u;
            byte[] d = new byte[u];
            System.arraycopy(fs.full, pos, d, 0, u);
            fs.decBlocks[i] = d;
            pos += u;
        }
    }
}

"""Minimal UnityFS reader/writer for CRC work.

Unity checks a bundle's CRC as CRC32 of the *decompressed* block stream. This
module decompresses that stream, rewrites a bundle from a (modified) stream
with uncompressed or LZ4HC blocks, and forges 4 chosen bytes so the stream CRC
equals a target value.
"""
import struct
import zlib

import lz4.block


def _cstr(b, p):
    e = b.index(b"\0", p)
    return b[p:e], e + 1


def _lzma(chunk, usize):
    """Unity LZMA block: 5 property bytes then a raw LZMA1 stream."""
    import lzma
    props = chunk[0]
    lc, lp, pb = props % 9, (props // 9) % 5, props // 45
    dict_size = struct.unpack("<I", chunk[1:5])[0]
    d = lzma.LZMADecompressor(lzma.FORMAT_RAW, filters=[{"id": lzma.FILTER_LZMA1, "lc": lc, "lp": lp,
                                                         "pb": pb, "dict_size": dict_size}])
    return d.decompress(chunk[5:], max_length=usize)


def parse(data):
    p = 0
    sig, p = _cstr(data, p)
    ver = struct.unpack(">I", data[p:p + 4])[0]; p += 4
    uver, p = _cstr(data, p)
    urev, p = _cstr(data, p)
    hdr_end_fields = p
    size, csz, usz, flags = struct.unpack(">qIII", data[p:p + 20]); p += 20
    if ver >= 7:
        p += (16 - p % 16) % 16
    if flags & 0x80:  # blocks info at end
        bi_raw = data[len(data) - csz:]
        data_start = p
    else:
        bi_raw = data[p:p + csz]
        p += csz
        if flags & 0x200:
            p += (16 - p % 16) % 16
        data_start = p
    comp = flags & 0x3F
    bi = lz4.block.decompress(bi_raw, uncompressed_size=usz) if comp in (2, 3) else bi_raw
    q = 16
    nblocks = struct.unpack(">I", bi[q:q + 4])[0]; q += 4
    blocks = []
    for _ in range(nblocks):
        u, c, f = struct.unpack(">IIH", bi[q:q + 10]); q += 10
        blocks.append((u, c, f))
    nnodes = struct.unpack(">I", bi[q:q + 4])[0]; q += 4
    nodes = []
    for _ in range(nnodes):
        off, sz, fl = struct.unpack(">qqI", bi[q:q + 20]); q += 20
        name, q = _cstr(bi, q)
        nodes.append((off, sz, fl, name))
    stream = bytearray()
    p = data_start
    for u, c, f in blocks:
        chunk = data[p:p + c]; p += c
        t = f & 0x3F
        if t == 0:
            stream += chunk
        elif t in (2, 3):
            stream += lz4.block.decompress(chunk, uncompressed_size=u)
        elif t == 1:
            stream += _lzma(chunk, u)
        else:
            raise ValueError(f"unsupported block compression {t}")
    return {"sig": sig, "ver": ver, "uver": uver, "urev": urev, "flags": flags,
            "blocks": blocks, "nodes": nodes, "stream": bytes(stream), "bi_hash": bi[:16]}


def crc(data):
    return zlib.crc32(parse(data)["stream"]) & 0xFFFFFFFF


def forge(stream, pos, target):
    """Overwrite stream[pos:pos+4] so that crc32(stream) == target."""
    s = bytearray(stream)
    s[pos:pos + 4] = b"\0\0\0\0"
    # CRC32 is affine over GF(2): find the 4 bytes by solving with 32 basis vectors
    base = zlib.crc32(bytes(s)) & 0xFFFFFFFF
    cols = []
    for bit in range(32):
        t = bytearray(s)
        t[pos + bit // 8] ^= 1 << (bit % 8)
        cols.append((zlib.crc32(bytes(t)) & 0xFFFFFFFF) ^ base)
    want = base ^ target
    # Gaussian elimination over GF(2)
    rows = [(cols[i], 1 << i) for i in range(32)]
    basis = []
    for v, m in rows:
        for bv, bm in basis:
            if v ^ bv < v:
                v ^= bv; m ^= bm
        if v:
            basis.append((v, m))
            basis.sort(reverse=True)
    sol, w = 0, want
    for bv, bm in basis:
        if w ^ bv < w:
            w ^= bv; sol ^= bm
    if w:
        raise ValueError("CRC not reachable")
    for bit in range(32):
        if sol >> bit & 1:
            s[pos + bit // 8] ^= 1 << (bit % 8)
    assert zlib.crc32(bytes(s)) & 0xFFFFFFFF == target
    return bytes(s)


def build(info, stream, block_size=0x20000):
    """Write a UnityFS bundle around stream: LZ4HC blocks, blocks info LZ4HC-compressed inline."""
    import lz4.block as L
    blocks, payload = [], bytearray()
    for i in range(0, len(stream), block_size):
        u = stream[i:i + block_size]
        c = L.compress(u, mode="high_compression", compression=9, store_size=False)
        if len(c) < len(u):
            blocks.append((len(u), len(c), 3)); payload += c
        else:
            blocks.append((len(u), len(u), 0)); payload += u
    bi = bytearray(info["bi_hash"])
    bi += struct.pack(">I", len(blocks))
    for u, c, f in blocks:
        bi += struct.pack(">IIH", u, c, f)
    bi += struct.pack(">I", len(info["nodes"]))
    for off, sz, fl, name in info["nodes"]:
        bi += struct.pack(">qqI", off, sz, fl) + name + b"\0"
    bic = L.compress(bytes(bi), mode="high_compression", compression=9, store_size=False)
    flags = (info["flags"] & ~0x3F & ~0x80) | 3
    head = info["sig"] + b"\0" + struct.pack(">I", info["ver"]) + info["uver"] + b"\0" + info["urev"] + b"\0"
    pre = len(head) + 20
    pad1 = (16 - pre % 16) % 16 if info["ver"] >= 7 else 0
    after_bi = pre + pad1 + len(bic)
    pad2 = (16 - after_bi % 16) % 16 if flags & 0x200 else 0
    total = after_bi + pad2 + len(payload)
    out = head + struct.pack(">qIII", total, len(bic), len(bi), flags) + b"\0" * pad1 + bic + b"\0" * pad2 + payload
    assert len(out) == total
    return out

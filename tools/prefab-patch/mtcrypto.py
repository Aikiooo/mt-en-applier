"""MasterData crypto for the PC client (same scheme as app/.../core/MasterCrypto.java).

AES-256-CBC + PKCS7, key/IV stored in global-metadata.dat with each byte +0x7F.
The PC offsets differ from Android's (0xbc3df0/0xbc6870): for client 1.2.0 they
are 0xba5ab8 (key) and 0xba8538 (IV). `find_keys` rediscovers them after an
update: with CBC, blocks 1.. of a table decrypt with the key alone, so each
candidate key is tested on a real table, then the IV is solved from "id\t".

Print the key/IV (hex) for a client build:
  python -I -X utf8 mtcrypto.py <global-metadata.dat> <language bundle>
"""
import json
import sys

import UnityPy
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad

KNOWN_OFFSETS = [(0xBA5AB8, 0xBA8538), (0xBC3DF0, 0xBC6870)]  # PC 1.2.0, then Android (client 1.2.0)


def decode(raw):
    return bytes((b - 0x7F) & 0xFF for b in raw)


def text_assets(bundle):
    """{name: (script bytes, object)} for every TextAsset, read raw (m_Script as str is lossy)."""
    env = UnityPy.load(bundle)
    out = {}
    for obj in env.objects:
        if obj.type.name == "TextAsset":
            raw = obj.get_raw_data()
            name, script = split_text_asset(raw)
            out[name] = (script, obj)
    return env, out


def split_text_asset(raw):
    # UnityPy's get_raw_data() returns a memoryview in some versions (the pinned
    # 1.25.4 returns bytes); both slices and decodes need a bytes-like.
    raw = bytes(raw)
    nlen = int.from_bytes(raw[:4], "little")
    name = raw[4:4 + nlen].decode("utf-8")
    p = 4 + nlen
    p += (4 - p % 4) % 4
    slen = int.from_bytes(raw[p:p + 4], "little")
    return name, raw[p + 4:p + 4 + slen]


def join_text_asset(raw, script):
    """Rebuild a TextAsset object (m_Name, m_Script) around a new script payload."""
    nlen = int.from_bytes(raw[:4], "little")
    p = 4 + nlen
    p += (4 - p % 4) % 4
    body = raw[:p] + len(script).to_bytes(4, "little") + script
    return body + b"\0" * ((4 - len(body) % 4) % 4)


def decrypt(ct, key, iv):
    pt = AES.new(key, AES.MODE_CBC, iv).decrypt(ct)
    n = pt[-1]
    if 1 <= n <= 16:
        pt = pt[:-n]
    return pt.decode("utf-8").rstrip("\n")


def encrypt(text, key, iv):
    return AES.new(key, AES.MODE_CBC, iv).encrypt(pad((text + "\n").encode("utf-8"), 16))


def _body_ok(key, ct):
    body = AES.new(key, AES.MODE_CBC, ct[:16]).decrypt(ct[16:])
    n = body[-1]
    if not 1 <= n <= 16 or body[-n:] != bytes([n]) * n:
        return False
    for skip in range(4):  # block 1 may start mid-character
        try:
            txt = body[skip:-n].decode("utf-8")
            return "\t" in txt and "\n" in txt
        except UnicodeDecodeError:
            pass
    return False


def _plausible(block):
    if any(b < 0x09 or 0x0B <= b < 0x20 for b in block):
        return False
    for a in range(4):
        for b in range(4):
            try:
                block[a:len(block) - b].decode("utf-8")
                return True
            except UnicodeDecodeError:
                pass
    return False


def find_keys(metadata_path, bundle_path):
    meta = open(metadata_path, "rb").read()
    _, tabs = text_assets(bundle_path)
    ct = min((s for n, (s, _) in tabs.items() if n.startswith("e_") and len(s) % 16 == 0 and len(s) >= 64), key=len)
    c0, c1 = ct[:16], ct[16:32]

    def iv_for(key, ko):
        d0 = AES.new(key, AES.MODE_ECB).decrypt(c0)
        lo, hi = max(0, ko - 0x10000), min(len(meta) - 16, ko + 0x10000)

        def iv_at(io):
            iv = decode(meta[io:io + 16])
            pt0 = bytes(a ^ b for a, b in zip(d0, iv))
            if pt0.startswith(b"id\t"):
                try:
                    pt0.decode("utf-8")
                    return iv
                except UnicodeDecodeError:
                    pass
            return None

        for io in range(lo, hi):            # the IV sits near the key
            iv = iv_at(io)
            if iv:
                return iv, io
        for io in range(len(meta) - 16):
            if lo <= io < hi:
                continue
            iv = iv_at(io)
            if iv:
                return iv, io
        return None, None

    for ko, io in KNOWN_OFFSETS:
        key, iv = decode(meta[ko:ko + 32]), decode(meta[io:io + 16])
        if _body_ok(key, ct) and AES.new(key, AES.MODE_CBC, iv).decrypt(c0).startswith(b"id\t"):
            return key, iv, ko, io

    # Fallback for a build whose metadata moved the key: the offsets shift by a
    # few KB, so scan the neighbourhoods of the known ones first and only then
    # the whole file. One AES block per candidate is the entire cost, since
    # _plausible rejects almost all of them (a minute or two on 23 MB).
    near = set()
    for k in (o for pair in KNOWN_OFFSETS for o in pair):
        near.update(range(max(0, k - 0x20000), min(len(meta) - 32, k + 0x20000)))

    def try_key(ko):
        key = decode(meta[ko:ko + 32])
        p1 = bytes(a ^ b for a, b in zip(AES.new(key, AES.MODE_ECB).decrypt(c1), c0))
        if _plausible(p1) and _body_ok(key, ct):
            iv, io = iv_for(key, ko)
            if iv:
                return key, iv, ko, io
        return None

    for ko in near:
        hit = try_key(ko)
        if hit:
            return hit
    print(f"key not near a known offset; scanning {len(meta) // 1024} KB of metadata ...",
          file=sys.stderr, flush=True)
    for ko in range(len(meta) - 32):
        if ko in near:
            continue
        hit = try_key(ko)
        if hit:
            return hit
    raise SystemExit("AES key not found in " + metadata_path)


if __name__ == "__main__":
    k, v, ko, io = find_keys(sys.argv[1], sys.argv[2])
    print(json.dumps({"key_hex": k.hex(), "iv_hex": v.hex(), "key_off": hex(ko), "iv_off": hex(io)}))

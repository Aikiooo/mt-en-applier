"""Build a PC (DMM) language bundle for another locale from the English one.

The installer (tools/pc/Install-EnPatch.ps1) offers every locale whose version.json
entry has a "pc.language" bundle. That bundle has to load exactly like the English
one: the catalog pins its byte size and the game checks its CRC. This builds it
from the released English bundle:

  1. Text: every cell of the 141 e_* tables is mapped back from English to its
     Japanese source through the English translation cache, then to the locale
     through the locale's cache. When one English text has several Japanese
     sources with different translations, the most common one wins. Cells with
     no translation (names, numbers, untranslated lines) keep the English text.
  2. Size: the English bundle reaches the stock size with newlines appended to
     its tables (the game's TSV parser ignores trailing empty lines). The locale
     tables are padded the same way, blocks are stored raw (ciphertext does not
     compress), and only a small leading block holding the serialized header is
     LZ4HC-compressed; its length is chosen so the file lands on the exact size.
  3. CRC: 4 bytes of alignment padding are forged so the stream CRC equals the
     English bundle's (unityfs.forge), as build_inapp.py does.

  python -I -X utf8 build_locale_bundle.py --language-bundle language-ja_en.bundle \
      --en-cache translation_cache.json --locale-cache translation_cache.fr.json \
      --out language-ja_fr.bundle [--metadata …\\global-metadata.dat | --game-dir DIR]

The caches are the files Build-TranslationCache.ps1 writes ({"cache": {jp: text}}).
Publish the result with tools/translations/Publish-Locale.ps1 -PcPatchFile.
"""
import argparse
import collections
import hashlib
import json
import os
import struct
import sys

import lz4.block
import UnityPy

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mtcrypto  # noqa: E402
import paths  # noqa: E402
import unityfs  # noqa: E402

BLOCK = 0x20000
PAD_TABLE = "e_scenario_text"   # the table that carries the size padding


def load_cache(path):
    return json.load(open(path, encoding="utf-8"))["cache"]


def translate_tables(tables, en_cache, loc_cache):
    """{name: english tsv} -> {name: locale tsv}, plus per-kind cell counts."""
    back = collections.defaultdict(collections.Counter)
    for jp, en in en_cache.items():
        if jp in loc_cache:
            back[en][loc_cache[jp]] += 1
    stats = collections.Counter()
    out = {}
    for name, text in tables.items():
        rows = text.split("\n")
        new_rows = [rows[0]]
        for row in rows[1:]:
            cells = row.split("\t")
            for c in range(1, len(cells)):
                cell = cells[c]
                if not cell or cell.isdigit():
                    continue
                if cell in back:
                    cells[c] = back[cell].most_common(1)[0][0]
                    stats["translated" if len(back[cell]) == 1 else "translated_ambiguous"] += 1
                else:
                    stats["kept_english"] += 1
            new_rows.append("\t".join(cells))
        out[name] = "\n".join(new_rows)
    return out, stats


def assemble(info, stream, head_len):
    """UnityFS file: a head_len-byte LZ4HC block (the compressible serialized
    header), then raw blocks. head_len moves the file size a few bytes at a time."""
    blocks, payload = [], bytearray()
    c = lz4.block.compress(stream[:head_len], mode="high_compression", compression=12, store_size=False)
    blocks.append((head_len, len(c), 3)); payload += c
    for i in range(head_len, len(stream), BLOCK):
        u = stream[i:i + BLOCK]
        blocks.append((len(u), len(u), 0)); payload += u
    bi = bytearray(info["bi_hash"]) + struct.pack(">I", len(blocks))
    for u, c, f in blocks:
        bi += struct.pack(">IIH", u, c, f)
    bi += struct.pack(">I", len(info["nodes"]))
    for off, sz, fl, name in info["nodes"]:
        bi += struct.pack(">qqI", off, sz, fl) + name + b"\0"
    bic = lz4.block.compress(bytes(bi), mode="high_compression", compression=9, store_size=False)
    flags = (info["flags"] & ~0x3F & ~0x80) | 3
    head = info["sig"] + b"\0" + struct.pack(">I", info["ver"]) + info["uver"] + b"\0" + info["urev"] + b"\0"
    pre = len(head) + 20
    pad1 = (16 - pre % 16) % 16 if info["ver"] >= 7 else 0
    after_bi = pre + pad1 + len(bic)
    pad2 = (16 - after_bi % 16) % 16 if flags & 0x200 else 0
    total = after_bi + pad2 + len(payload)
    return (head + struct.pack(">qIII", total, len(bic), len(bi), flags) + b"\0" * pad1 + bic
            + b"\0" * pad2 + bytes(payload))


def make_stream(src, key, iv, tables, newlines, target_crc):
    """Decompressed stream of src with the locale tables in, PAD_TABLE padded, CRC forged."""
    env = UnityPy.load(src)
    for obj in env.objects:
        if obj.type.name != "TextAsset":
            continue
        raw = bytes(obj.get_raw_data())
        name, _ = mtcrypto.split_text_asset(raw)
        if name in tables:
            text = tables[name] + ("\n" * newlines if name == PAD_TABLE else "")
            obj.set_raw_data(mtcrypto.join_text_asset(raw, mtcrypto.encrypt(text, key, iv)))
    data = env.file.save(packer="original")
    info = unityfs.parse(data)
    sf = next(f for f in UnityPy.load(data).file.files.values() if hasattr(f, "objects"))
    objs = sorted(sf.objects.values(), key=lambda o: o.byte_start)
    node0 = next(off for off, _, _, n in info["nodes"] if not n.endswith((b".resS", b".resource")))
    pos = next(node0 + a.byte_start + a.byte_size for a, b in zip(objs, objs[1:])
               if b.byte_start - (a.byte_start + a.byte_size) >= 4
               and info["stream"][node0 + a.byte_start + a.byte_size:node0 + a.byte_start + a.byte_size + 4] == b"\0" * 4)
    return info, unityfs.forge(info["stream"], pos, target_crc)


def build(src, key, iv, tables):
    target, target_crc = len(src), unityfs.crc(src)
    info, stream = make_stream(src, key, iv, tables, 0, target_crc)
    unpadded = len(assemble(info, stream, 4096))
    if unpadded > target:
        raise SystemExit(f"locale text too long: {unpadded} B before padding, the stock size is {target} B")
    # every 16 newlines add exactly 16 bytes of ciphertext; head_len absorbs the rest
    newlines = max(0, (target - unpadded) // 16 * 16 - 64)
    for _ in range(64):
        info, stream = make_stream(src, key, iv, tables, newlines, target_crc)
        sizes = []
        for head_len in range(1024, 32768):
            out = assemble(info, stream, head_len)
            if len(out) == target:
                assert unityfs.crc(out) == target_crc
                return out, newlines
            sizes.append(len(out))
        newlines += 16 if max(sizes) < target else -16
    raise SystemExit("no exact-size layout found")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--language-bundle", required=True, help="released English language-ja_en.bundle")
    ap.add_argument("--en-cache", required=True, help="English translation_cache.json")
    ap.add_argument("--locale-cache", required=True, help="translation_cache.<locale>.json")
    ap.add_argument("--out", required=True)
    ap.add_argument("--game-dir")
    ap.add_argument("--metadata", help="global-metadata.dat (default: the installed one)")
    a = ap.parse_args()

    src = open(a.language_bundle, "rb").read()
    meta = a.metadata or paths.metadata_path(a.game_dir or paths.game_dir())
    key, iv, _, _ = mtcrypto.find_keys(meta, a.language_bundle)
    _, assets = mtcrypto.text_assets(src)
    english = {n: mtcrypto.decrypt(s, key, iv) for n, (s, _) in assets.items() if n.startswith("e_")}
    tables, stats = translate_tables(english, load_cache(a.en_cache), load_cache(a.locale_cache))
    data, newlines = build(src, key, iv, tables)

    # read back: every table must decrypt to the locale text
    _, check = mtcrypto.text_assets(data)
    for n, text in tables.items():
        assert mtcrypto.decrypt(check[n][0], key, iv) == text, n
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    open(a.out, "wb").write(data)
    print(json.dumps({"out": a.out, "size": len(data), "md5": hashlib.md5(data).hexdigest(),
                      "crc": "%08x" % unityfs.crc(data), "english_size": len(src),
                      "tables": len(tables), "padding_newlines": newlines, **stats}, indent=1))


if __name__ == "__main__":
    main()

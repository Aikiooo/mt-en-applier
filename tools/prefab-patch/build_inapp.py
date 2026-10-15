"""Build the English inapp_assets_all.bundle for PC (StreamingAssets).

Why: on the first load the title screen runs entirely from this in-app bundle,
which carries its own (Japanese/dev) copy of the 140 e_* tables plus baked
prefab text. The downloaded language bundle only takes over after login,
hence "load twice for full English".

This rebuilds the stock bundle with:
  1. its e_* tables replaced by the English tables decrypted from the released
     language bundle (same headers; re-encrypted, no size limit here),
  2. its prefab m_text translated (see prefab_text.py),
  3. its CRC forged back to the stock value. The game loads this bundle with
     the stock CRC even though the local catalog declares none (Player.log:
     "CRC Mismatch. Provided …, calculated … Will not load AssetBundle
     inapp_assets_all.bundle", which is the black screen). Unity's CRC is a
     CRC32 of the decompressed stream; 4 bytes of alignment padding between two
     serialized objects (never read) are set so it matches.

DMM GAME PLAYER verifies this file before starting the game, so it cannot stay
installed: tools/pc/Watch-InappSwap.ps1 swaps it in after DMM has launched the
game and restores the stock file when the game exits.

  python -I -X utf8 build_inapp.py --language-bundle language-ja_en.bundle \
      --translation-cache translation_cache.json [--stock …\\inapp_assets_all.bundle] [--out FILE]
"""
import argparse
import hashlib
import json
import os
import sys

import UnityPy

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mtcrypto  # noqa: E402
import paths  # noqa: E402
import unityfs  # noqa: E402
from prefab_text import CJK, Translator, replace, texts  # noqa: E402

REPO = os.path.normpath(os.path.join(HERE, "..", ".."))


def forge_crc(data, target):
    info = unityfs.parse(data)
    env = UnityPy.load(data)
    sf = next(f for f in env.file.files.values() if hasattr(f, "objects"))
    node0 = next(off for off, _, _, name in info["nodes"] if not name.endswith((b".resS", b".resource")))
    objs = sorted(sf.objects.values(), key=lambda o: o.byte_start)
    for a, b in zip(objs, objs[1:]):
        end = a.byte_start + a.byte_size
        if b.byte_start - end >= 4 and info["stream"][node0 + end:node0 + end + 4] == b"\0\0\0\0":
            out = unityfs.build(info, unityfs.forge(info["stream"], node0 + end, target))
            assert unityfs.crc(out) == target
            return out
    raise SystemExit("no 4-byte padding gap found to forge the CRC")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--language-bundle", required=True, help="released English language-ja_en.bundle")
    ap.add_argument("--translation-cache", required=True)
    ap.add_argument("--prefab-map", default=os.path.join(REPO, "translations", "en", "prefab", "ui-prefab.json"))
    ap.add_argument("--game-dir")
    ap.add_argument("--stock", help="stock inapp_assets_all.bundle (default: the installed one)")
    ap.add_argument("--metadata", help="global-metadata.dat (default: the installed one)")
    ap.add_argument("--out", default=os.path.join(REPO, "build", "inapp_assets_all_en.bundle"))
    a = ap.parse_args()

    gdir = a.game_dir or (None if (a.stock and a.metadata) else paths.game_dir())
    stock_path = a.stock or paths.inapp_path(gdir)
    key, iv, ko, io = mtcrypto.find_keys(a.metadata or paths.metadata_path(gdir), a.language_bundle)
    print(f"AES key at {ko:#x}, IV at {io:#x}", flush=True)

    _, lang = mtcrypto.text_assets(a.language_bundle)
    english = {n: mtcrypto.decrypt(s, key, iv) for n, (s, _) in lang.items() if n.startswith("e_")}

    stock = open(stock_path, "rb").read()
    env = UnityPy.load(stock)
    tr = Translator(a.translation_cache, a.prefab_map)
    tables = fields = 0
    skipped = []
    for obj in env.objects:
        if obj.type.name == "TextAsset":
            raw = obj.get_raw_data()
            name, script = mtcrypto.split_text_asset(raw)
            if not name.startswith("e_") or name not in english:
                continue
            ja = mtcrypto.decrypt(script, key, iv)
            if ja.split("\n")[0] != english[name].split("\n")[0]:
                skipped.append(name)  # columns changed: keep the stock table
                continue
            obj.set_raw_data(mtcrypto.join_text_asset(raw, mtcrypto.encrypt(english[name], key, iv)))
            tables += 1
        elif obj.type.name == "MonoBehaviour":
            try:
                tree = obj.read_typetree()
            except Exception:
                continue
            ja = [t for t in texts(tree) if CJK.search(t)]
            if ja:
                n = replace(tree, tr.build(ja))
                if n:
                    obj.save_typetree(tree)
                    fields += n

    data = forge_crc(env.file.save(packer="original"), unityfs.crc(stock))
    # read back: every replaced table must decrypt to the English text
    _, check = mtcrypto.text_assets(data)
    for n, (s, _) in check.items():
        if n in english and n not in skipped:
            assert mtcrypto.decrypt(s, key, iv) == english[n], n
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    open(a.out, "wb").write(data)
    info = {"stock_md5": hashlib.md5(stock).hexdigest(), "stock_size": len(stock),
            "md5": hashlib.md5(data).hexdigest(), "size": len(data), "crc": f"{unityfs.crc(data):08x}",
            "tables": tables, "text_fields": fields, "tables_kept_stock": skipped, "untranslated": len(tr.untranslated)}
    json.dump(info, open(a.out + ".json", "w"), indent=1)
    print(json.dumps(info))


if __name__ == "__main__":
    main()

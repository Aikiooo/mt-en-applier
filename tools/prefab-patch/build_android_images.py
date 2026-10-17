"""Android image patch: the redrawn textures, re-encoded into the game's Android bundles.

Superseded by build_android_prefabs.py, which builds the same zip (plus the menu text)
from the game's CDN instead of bundles pulled from a phone. Kept for a stock folder at hand.

The Android client caches the same bundles as PC under the same name folder
(UnityCache/Shared/<name hash>/<version hash>/__data); only the version folder
differs. Its textures are ASTC 6x6 without mips, which textures.set_image keeps.

Input is a folder of stock (Japanese) Android bundles, each file named after its
name folder, e.g. pulled from a phone with adb:

    for d in <name folders>; do cp "$(ls -t Shared/$d/*/__data | head -1)" out/$d; done

Output is one zip per language, read by the app (MainActivity.installImages):

    manifest.json   [{"bundle": name folder, "src_md5", "out_md5", "size", "textures"}]
    <name folder>   the patched bundle

The app overwrites a cached bundle only when its md5 is src_md5 (stock) or one
the app wrote itself, so a game update that changes a bundle leaves it stock.

    py -I -X utf8 tools/prefab-patch/build_android_images.py --stock <dir> --locale fr
"""
import argparse
import hashlib
import json
import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import UnityPy  # noqa: E402
from textures import texture_files, set_textures  # noqa: E402

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
FIXED_TIME = (2020, 1, 1, 0, 0, 0)   # deterministic zips


def md5(b):
    return hashlib.md5(b).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stock", required=True, help="folder of stock Android bundles named by name folder")
    ap.add_argument("--locale", required=True, help="translations/<locale>/textures is used")
    ap.add_argument("--out", help="zip path (default build/android-images-<locale>.zip)")
    a = ap.parse_args()

    files = texture_files(os.path.join(REPO, "translations", a.locale, "textures"))
    if not files:
        raise SystemExit(f"no textures in translations/{a.locale}/textures")
    out = a.out or os.path.join(REPO, "build", f"android-images-{a.locale}.zip")
    os.makedirs(os.path.dirname(out), exist_ok=True)

    manifest, blobs, used = [], {}, set()
    for name in sorted(os.listdir(a.stock)):
        src = open(os.path.join(a.stock, name), "rb").read()
        env = UnityPy.load(src)
        written = set_textures(env, files)
        if not written:
            continue
        data = env.file.save(packer="original")
        used.update(written)
        manifest.append({"bundle": name, "src_md5": md5(src), "out_md5": md5(data),
                         "size": len(data), "textures": sorted(set(written))})
        blobs[name] = data

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        def put(n, b):
            zi = zipfile.ZipInfo(n, FIXED_TIME)
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, b)
        put("manifest.json", json.dumps(manifest, indent=1).encode())
        for n in sorted(blobs):
            put(n, blobs[n])

    print(f"{len(manifest)} bundles, {len(used)} of {len(files)} textures -> {out}")
    print(f"  {os.path.getsize(out):,} bytes, md5 {md5(open(out, 'rb').read())}")
    missing = sorted(set(files) - used)
    if missing:
        print(f"  not in these bundles: {', '.join(missing)}")


if __name__ == "__main__":
    main()

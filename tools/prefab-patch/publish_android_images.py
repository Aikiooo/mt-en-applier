"""Publish a language's Android UI zips (menu text, images) to the patch-latest release.

Uploads build/android-prefabs-<locale>.zip and/or build/android-images-<locale>.zip
(from build_android_prefabs.py), then merges their keys into the live version.json:

    prefabs / prefabs_md5 / prefabs_size   the menu text (UI prefabs)
    images  / images_md5  / images_size    the redrawn images

top-level for the default language (English), "locales.<locale>" otherwise. Every
other key is left as it is. Without --publish it only prints the change.

    py -I -X utf8 tools/prefab-patch/publish_android_images.py --locale fr [--kind prefabs images]
    py -I -X utf8 tools/prefab-patch/publish_android_images.py --locale fr --kind prefabs images --publish

update_translation.py rewrites version.json from scratch on an English release:
re-run this script (and Publish-Locale.ps1) for each language afterwards.
"""
import argparse
import collections
import hashlib
import json
import os
import subprocess
import tempfile
import zipfile

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
GH_REPO = "Aikiooo/mt-en-applier"
TAG = "patch-latest"
KINDS = {"images": "android-images", "prefabs": "android-prefabs"}


def gh(*args):
    subprocess.run(["gh", *args, "--repo", GH_REPO], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--locale", required=True)
    ap.add_argument("--kind", nargs="+", choices=sorted(KINDS), default=["images"])
    ap.add_argument("--dir", default=os.path.join(REPO, "build"), help="where the zips are")
    ap.add_argument("--publish", action="store_true", help="upload (default: dry run)")
    a = ap.parse_args()

    registry = json.load(open(os.path.join(REPO, "translations", "locales.json"), encoding="utf-8"))
    default = registry["default"]
    if a.locale != default and a.locale not in registry["locales"]:
        raise SystemExit(f"unknown locale '{a.locale}' (translations/locales.json)")
    zips, fields = [], {}
    for kind in a.kind:
        asset = f"{KINDS[kind]}-{a.locale}.zip"
        zpath = os.path.join(a.dir, asset)
        data = open(zpath, "rb").read()
        names = json.loads(zipfile.ZipFile(zpath).read("manifest.json"))
        if not names:
            raise SystemExit(f"{asset} has no bundles")
        zips.append(zpath)
        fields.update({kind: asset, f"{kind}_md5": hashlib.md5(data).hexdigest(), f"{kind}_size": len(data)})

    tmp = tempfile.mkdtemp()
    gh("release", "download", TAG, "-p", "version.json", "-D", tmp, "--clobber")
    vpath = os.path.join(tmp, "version.json")
    v = json.load(open(vpath, encoding="utf-8"), object_pairs_hook=collections.OrderedDict)
    if a.locale == default:
        block = v
    else:
        block = v.get("locales", {}).get(a.locale)
        if block is None:
            raise SystemExit(f"'{a.locale}' is not published yet: run Publish-Locale.ps1 first")
    before = {k: block.get(k) for k in fields}
    block.update(fields)
    where = "version.json" if a.locale == default else f"version.json locales.{a.locale}"
    print(f"{where}:")
    for k in fields:
        print(f"  {k}: {before[k]!r} -> {fields[k]!r}")
    if not a.publish:
        print("dry run: nothing uploaded (add --publish)")
        return

    # the zips first, version.json last: the app must never list a missing file
    for z in zips:
        gh("release", "upload", TAG, z, "--clobber")
    with open(vpath, "w", encoding="utf-8", newline="\n") as f:
        json.dump(v, f, ensure_ascii=False)
    gh("release", "upload", TAG, vpath, "--clobber")
    print("published")


if __name__ == "__main__":
    main()

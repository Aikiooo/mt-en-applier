"""Publish a language's Android image zip to the patch-latest release.

Uploads build/android-images-<locale>.zip (from build_android_images.py), then
merges "images" / "images_md5" / "images_size" into the live version.json:
top-level for the default language (English), "locales.<locale>" otherwise.
Every other key is left as it is. Without --publish it only prints the change.

    py -I -X utf8 tools/prefab-patch/publish_android_images.py --locale fr
    py -I -X utf8 tools/prefab-patch/publish_android_images.py --locale fr --publish

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

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
GH_REPO = "Aikiooo/mt-en-applier"
TAG = "patch-latest"


def gh(*args):
    subprocess.run(["gh", *args, "--repo", GH_REPO], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--locale", required=True)
    ap.add_argument("--zip", help="default build/android-images-<locale>.zip")
    ap.add_argument("--publish", action="store_true", help="upload (default: dry run)")
    a = ap.parse_args()

    registry = json.load(open(os.path.join(REPO, "translations", "locales.json"), encoding="utf-8"))
    default = registry["default"]
    if a.locale != default and a.locale not in registry["locales"]:
        raise SystemExit(f"unknown locale '{a.locale}' (translations/locales.json)")
    zpath = a.zip or os.path.join(REPO, "build", f"android-images-{a.locale}.zip")
    asset = f"android-images-{a.locale}.zip"
    data = open(zpath, "rb").read()
    fields = {"images": asset, "images_md5": hashlib.md5(data).hexdigest(), "images_size": len(data)}

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
    print(f"{a.locale}: {before} -> {fields}")
    if not a.publish:
        print("dry run: nothing uploaded (add --publish)")
        return

    # the zip first, version.json last: the app must never list a missing file
    if os.path.basename(zpath) != asset:
        raise SystemExit(f"rename the zip to {asset} (gh names the asset after the file)")
    gh("release", "upload", TAG, zpath, "--clobber")
    with open(vpath, "w", encoding="utf-8", newline="\n") as f:
        json.dump(v, f, ensure_ascii=False)
    gh("release", "upload", TAG, vpath, "--clobber")
    print("published")


if __name__ == "__main__":
    main()

"""Publish Taiwan (com.cayenne.mtr) Android patch artifacts to patch-latest.

Reads build/tw/tw-build-summary.json (produced by build_tw_patch.py), merges
the nested "tw" block into the live version.json on patch-latest without
touching any JP top-level, "pc", or JP "locales" keys, and (with --publish)
uploads all TW assets first and version.json last.

Dry run by default (prints the merged "tw" block without uploading):
  python -I -X utf8 tools/prefab-patch/publish_tw_patch.py
  python -I -X utf8 tools/prefab-patch/publish_tw_patch.py --publish
"""
import argparse
import collections
import datetime
import hashlib
import json
import os
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
GH_REPO = "Aikiooo/mt-en-applier"
TAG = "patch-latest"


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def gh(*args):
    subprocess.run(["gh", *args, "--repo", GH_REPO], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=os.path.join(REPO, "build", "tw"))
    ap.add_argument("--game-version", default="1.1.3 / 2026-11-24")
    ap.add_argument("--publish", action="store_true", help="upload assets and version.json (default: dry run)")
    a = ap.parse_args()

    sum_path = os.path.join(a.dir, "tw-build-summary.json")
    summary = json.load(open(sum_path, encoding="utf-8"))
    registry = json.load(open(os.path.join(REPO, "translations", "locales.json"), encoding="utf-8"))
    now = datetime.datetime.now().isoformat(timespec="seconds")

    en = summary["locales"]["en"]
    uploads = []

    def require_asset(filename, expected_md5, expected_size):
        p = os.path.join(a.dir, filename)
        if not os.path.exists(p):
            raise SystemExit(f"missing built TW asset: {p}")
        got_md5 = md5_file(p)
        got_size = os.path.getsize(p)
        if got_md5 != expected_md5 or got_size != expected_size:
            raise SystemExit(f"{filename} changed since summary: md5={got_md5} size={got_size}")
        uploads.append(p)
        return filename, got_md5, got_size

    tmp = tempfile.mkdtemp()
    gh("release", "download", TAG, "-p", "version.json", "-D", tmp, "--clobber")
    vpath = os.path.join(tmp, "version.json")
    v = json.load(open(vpath, encoding="utf-8"), object_pairs_hook=collections.OrderedDict)

    prev_tw = v.get("tw") if isinstance(v.get("tw"), dict) else {}
    hist = [h for h in str(prev_tw.get("patch_md5_history", "")).split(",") if h]
    prev_md5 = prev_tw.get("patch_md5")
    if prev_md5 and prev_md5 != en["patch_md5"] and prev_md5 not in hist:
        hist.append(prev_md5)
    hist_str = ",".join(h for h in hist if h != en["patch_md5"])

    en_patch, en_patch_md5, en_patch_size = require_asset(en["patch"], en["patch_md5"], en["patch_size"])
    en_cache, en_cache_md5, _ = require_asset(en["cache"], en["cache_md5"], en["cache_size"])

    tw_block = collections.OrderedDict([
        ("game_version", a.game_version),
        ("stock_md5", summary["stock_md5"]),
        ("stock_size", summary["stock_size"]),
        ("lang_guid", summary["lang_guid"]),
        ("meta_key_off", summary["meta_key_off"]),
        ("meta_iv_off", summary["meta_iv_off"]),
        ("patch", en_patch),
        ("patch_size", en_patch_size),
        ("patch_md5", en_patch_md5),
        ("patch_md5_history", hist_str),
        ("cache", en_cache),
        ("cache_md5", en_cache_md5),
        ("built_at", now),
    ])
    if "prefabs" in en:
        pf, pmd5, psz = require_asset(en["prefabs"], en["prefabs_md5"], en["prefabs_size"])
        tw_block["prefabs"] = pf
        tw_block["prefabs_md5"] = pmd5
        tw_block["prefabs_size"] = psz
    if "images" in en:
        im, imd5, isz = require_asset(en["images"], en["images_md5"], en["images_size"])
        tw_block["images"] = im
        tw_block["images_md5"] = imd5
        tw_block["images_size"] = isz

    locales_out = collections.OrderedDict()
    for code, loc in summary["locales"].items():
        if code == "en":
            continue
        meta = registry["locales"].get(code, {})
        lp, lp_md5, lp_sz = require_asset(loc["patch"], loc["patch_md5"], loc["patch_size"])
        lc, lc_md5, _ = require_asset(loc["cache"], loc["cache_md5"], loc["cache_size"])
        entry = collections.OrderedDict([
            ("name", meta.get("name", code)),
            ("label", meta.get("label", code)),
            ("patch", lp),
            ("patch_size", lp_sz),
            ("patch_md5", lp_md5),
            ("stock_md5", summary["stock_md5"]),
            ("cache", lc),
            ("cache_md5", lc_md5),
            ("built_at", now),
        ])
        if "prefabs" in loc:
            pf, pmd5, psz = require_asset(loc["prefabs"], loc["prefabs_md5"], loc["prefabs_size"])
            entry["prefabs"] = pf
            entry["prefabs_md5"] = pmd5
            entry["prefabs_size"] = psz
        if "images" in loc:
            im, imd5, isz = require_asset(loc["images"], loc["images_md5"], loc["images_size"])
            entry["images"] = im
            entry["images_md5"] = imd5
            entry["images_size"] = isz
        locales_out[code] = entry
    if locales_out:
        tw_block["locales"] = locales_out

    v["tw"] = tw_block

    print("Merged 'tw' block:")
    print(json.dumps(tw_block, ensure_ascii=False, indent=2))
    print(f"\nAssets to upload ({len(uploads)}):")
    for p in uploads:
        print(f"  {os.path.basename(p)}  ({os.path.getsize(p):,} B)")

    if not a.publish:
        print("\nDry run: nothing uploaded (pass --publish to upload).")
        return

    # Assets first, version.json last so clients never see an unpublished file.
    gh("release", "upload", TAG, *uploads, "--clobber")
    with open(vpath, "w", encoding="utf-8", newline="\n") as f:
        json.dump(v, f, ensure_ascii=False, indent=1)
        f.write("\n")
    gh("release", "upload", TAG, vpath, "--clobber")
    print("Published TW assets and updated version.json on patch-latest.")


if __name__ == "__main__":
    main()

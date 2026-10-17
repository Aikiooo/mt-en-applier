"""Android UI patch: the text baked into the game's UI prefabs, and the redrawn images,
in the game's own Android bundles, rebuilt from CDN stock.

The PC patch (build_prefab_patch.py) and the iOS patch (tools/ios/build_ios_patch.py)
translate ~7,000 TextMeshPro / uGUI strings in 353 cached bundles (menus, buttons,
windows). Android caches the same bundles under the same name folder
(UnityCache/Shared/<m_BundleName>/<version>/__data), so the app installs them the way it
installs the images: overwrite a cached copy whose md5 is stock (src_md5) or one it wrote.

Stock comes from the CDN, never from a phone:

    https://mushokutensei-coe-jp.akamaized.net/production/client/<build>/<unity>/AssetBundle/Android/<name>_<hash>.bundle

Which bundles carry text or textures comes from the PC manifests on patch-latest
(prefab-patch.zip, prefab-images.zip), as for iOS. None of them has
m_UseCrcForCachedBundles in the Android catalog today (153 other bundles do); every
patched file still gets the catalog's CRC back (unityfs.forge), so it would load even if
the game started checking. A bundle the catalog checks is reported in the summary.

Two zips per language, same layout as before (MainActivity.installImages):

    android-prefabs-<code>.zip  text only, every bundle with Japanese prefab text
    android-images-<code>.zip   every bundle with a redrawn texture; where that bundle also
                                carries text, the text is in it too, so the image copy
                                replaces the text copy instead of undoing it

    manifest.json  [{"bundle", "src_md5", "out_md5", "size", "text_fields", "textures"}]
    <name folder>  the patched bundle

plus android-ui-<code>.json (catalog, counts, untranslated strings). Builds are
deterministic: the same CDN stock and translations give byte-identical zips.

    py -I -X utf8 tools/prefab-patch/build_android_prefabs.py --base-url <…/AssetBundle/Android>
        --release-dir <patch-latest files> [--locale en fr] [--no-images]

<patch-latest files>: prefab-patch.zip, prefab-images.zip and each language's cache
(translation_cache.json for English, translation_cache.<code>.json otherwise).
"""
import argparse
import base64
import hashlib
import json
import os
import re
import sys
import zipfile
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "tools", "ios"))
import unityfs  # noqa: E402
from build_ios_patch import catalog_bundles, fetch, forge_crc, pc_bundle_names, target_platform  # noqa: E402
from prefab_text import CJK, Translator, replace, texts  # noqa: E402
from textures import set_textures, texture_files  # noqa: E402

ANDROID_TARGET = 13     # BuildTarget.Android, in the serialized file header
FIXED_TIME = (2020, 1, 1, 0, 0, 0)   # deterministic zips


def md5(b):
    return hashlib.md5(b).hexdigest()


def cache_name(code):
    return "translation_cache.json" if code == "en" else f"translation_cache.{code}.json"


def crc_checked(catalog):
    """Bundle names the catalog verifies even when cached (m_UseCrcForCachedBundles)."""
    raw = base64.b64decode(catalog["m_ExtraDataString"])
    text = raw.decode("utf-16-le", "ignore") + raw[1:].decode("utf-16-le", "ignore")
    return set(re.findall(r'"m_BundleName":"([^"]+)"[^{}]*"m_UseCrcForCachedBundles":true', text))


# ---------------------------------------------------------------- one bundle

_tr = {}
_tex = {}


def _init(locales):
    """locales: {code: (cache path, prefab map path, textures dir or None)}"""
    global _tr, _tex
    for code, (cache, prefab_map, tex) in locales.items():
        _tr[code] = Translator(cache, prefab_map)
        _tex[code] = texture_files(tex)


def _text(env, tr):
    found, trees = [], []
    for obj in env.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        try:
            tree = obj.read_typetree()
        except Exception:
            continue
        ja = [t for t in texts(tree) if CJK.search(t)]
        if ja:
            found += ja
            trees.append((obj, tree))
    mapping = tr.build(found) if found else {}
    changed = 0
    for obj, tree in trees:
        n = replace(tree, mapping)
        if n:
            obj.save_typetree(tree)
            changed += n
    return changed, sorted(set(found) - set(mapping))


def patch(stock_path, crc, code):
    """{"text": bytes|None, "images": bytes|None, ...} for one stock bundle and language.
    text = text only; images = text and textures, only when a texture was written."""
    import UnityPy
    src = open(stock_path, "rb").read()
    if unityfs.crc(src) != crc:
        return {"error": "stock CRC %08x is not the catalog's %08x" % (unityfs.crc(src), crc)}
    if target_platform(src) != ANDROID_TARGET:
        return {"error": "not an Android bundle"}
    env = UnityPy.load(src)
    fields, untranslated = _text(env, _tr[code])
    res = {"text_fields": fields, "untranslated": untranslated, "textures": [], "text": None, "images": None}
    if fields:
        res["text"] = forge_crc(env.file.save(packer="original"), crc)
        env = UnityPy.load(res["text"])
    tex = set_textures(env, _tex[code])
    if tex:
        res["textures"] = sorted(set(tex))
        res["images"] = forge_crc(env.file.save(packer="original"), crc)
    for k in ("text", "images"):
        if res[k] is not None:
            assert unityfs.crc(res[k]) == crc
            UnityPy.load(res[k])
    return res


# ---------------------------------------------------------------- output

def write_zip(path, entries, blobs):
    with zipfile.ZipFile(path + ".part", "w", zipfile.ZIP_DEFLATED) as z:
        def put(n, b):
            zi = zipfile.ZipInfo(n, FIXED_TIME)
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, b)
        put("manifest.json", json.dumps(entries, indent=1).encode())
        for n in sorted(blobs):
            put(n, blobs[n])
    os.replace(path + ".part", path)
    data = open(path, "rb").read()
    print(f"  {os.path.basename(path)}: {len(entries)} bundles, {len(data):,} bytes, md5 {md5(data)}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True,
                    help="https://mushokutensei-coe-jp.akamaized.net/production/client/<build>/<unity>/AssetBundle/Android")
    ap.add_argument("--release-dir", required=True, help="folder with the patch-latest files (see above)")
    ap.add_argument("--locale", nargs="+", default=["en", "fr"])
    ap.add_argument("--out", default=os.path.join(REPO, "build"))
    ap.add_argument("--stock-dir", default=os.path.join(REPO, "build", "android-stock"), help="download cache")
    ap.add_argument("--no-images", action="store_true", help="only the text zips")
    ap.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    a = ap.parse_args()
    base = a.base_url.rstrip("/")
    rel = lambda n: os.path.join(a.release_dir, n)  # noqa: E731
    m = re.search(r"/client/([^/]+)/([^/]+)/AssetBundle/Android$", base)
    if not m:
        raise SystemExit("--base-url must end in /client/<build>/<unity>/AssetBundle/Android")

    locales = {}
    for code in a.locale:
        cache = rel(cache_name(code))
        pmap = os.path.join(REPO, "translations", code, "prefab", "ui-prefab.json")
        for p in (cache, pmap):
            if not os.path.exists(p):
                raise SystemExit(f"{code}: {p} is missing")
        tex = None if a.no_images else os.path.join(REPO, "translations", code, "textures")
        locales[code] = (cache, pmap, tex)

    catalog_hash = fetch(base + "/catalog_ja.hash").decode().strip()
    stock_dir = os.path.join(a.stock_dir, catalog_hash)
    catalog = json.loads(fetch(base + "/catalog_ja.json", os.path.join(stock_dir, "catalog_ja.json")))
    cat = catalog_bundles(catalog)
    checked = crc_checked(catalog)
    print(f"catalog {catalog_hash}: {len(cat)} bundles", flush=True)

    want = sorted(pc_bundle_names([rel("prefab-patch.zip"), rel("prefab-images.zip")]))
    missing = [n for n in want if n not in cat]
    want = [n for n in want if n in cat]
    with ThreadPoolExecutor(8) as ex:   # small files from a CDN in Japan: the time is in round trips
        list(ex.map(lambda n: fetch(base + "/" + cat[n]["file"], os.path.join(stock_dir, cat[n]["file"])), want))
    print(f"ui: {len(want)} bundles ({len(missing)} of the PC list not on Android, "
          f"{len(checked & set(want))} CRC-checked when cached)", flush=True)

    out = {c: {"text": ([], {}), "images": ([], {}), "untranslated": set(), "fields": 0} for c in locales}
    errors = []
    with ProcessPoolExecutor(a.workers, initializer=_init, initargs=(locales,)) as ex:
        futs = {ex.submit(patch, os.path.join(stock_dir, cat[n]["file"]), cat[n]["crc"], c): (n, c)
                for n in want for c in locales}
        for fu in as_completed(futs):
            (n, c), r = futs[fu], fu.result()
            if "error" in r:
                errors.append(f"{cat[n]['file']}: {r['error']}")
                continue
            o = out[c]
            o["untranslated"].update(r["untranslated"])
            o["fields"] += r["text_fields"]
            src_md5 = md5(open(os.path.join(stock_dir, cat[n]["file"]), "rb").read())
            for kind in ("text", "images"):
                data = r[kind]
                if data is None:
                    continue
                entries, blobs = o[kind]
                entries.append({"bundle": n, "src_md5": src_md5, "out_md5": md5(data), "size": len(data),
                                "text_fields": r["text_fields"], "textures": r["textures"] if kind == "images" else []})
                blobs[n] = data
    if errors:
        raise SystemExit("stock bundles that don't match the catalog:\n  " + "\n  ".join(sorted(errors)[:10]))

    os.makedirs(a.out, exist_ok=True)
    for c, o in out.items():
        print(f"{c}: {o['fields']} text fields, {len(o['untranslated'])} untranslated strings", flush=True)
        summary = {"locale": c, "client_build": m.group(1), "unity": m.group(2), "catalog_hash": catalog_hash,
                   "crc_checked": sorted(checked & set(want)), "not_on_android": missing}
        for kind, name in (("text", "android-prefabs"), ("images", "android-images")):
            entries, blobs = o[kind]
            if kind == "images" and a.no_images:
                continue
            entries.sort(key=lambda e: e["bundle"])
            path = os.path.join(a.out, f"{name}-{c}.zip")
            write_zip(path, entries, blobs)
            summary[kind] = {"file": os.path.basename(path), "md5": md5(open(path, "rb").read()),
                             "size": os.path.getsize(path), "bundles": len(entries),
                             "text_fields": sum(e["text_fields"] for e in entries),
                             "textures": len({t for e in entries for t in e["textures"]})}
        summary["untranslated"] = sorted(o["untranslated"])
        with open(os.path.join(a.out, f"android-ui-{c}.json"), "w", encoding="utf-8", newline="\n") as f:
            json.dump(summary, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()

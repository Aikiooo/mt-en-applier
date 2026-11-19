"""PC menus + images from the CDN stock, no game and no Unity cache needed.

build_prefab_patch.py reads the bundles of the player's Unity cache, which only holds the
screens the game has opened since an update - so every client update needed someone to play
through the screens first. This does the same job from the CDN, the way build_android_prefabs.py
and tools/ios/build_ios_patch.py do:

    https://mushokutensei-coe-jp.akamaized.net/production/client/<build>/<unity>/AssetBundle/StandaloneWindows64/<name>_<hash>.bundle

The output is the same tree (manifest.json + <name>/<hash>/__data + untranslated.json +
crc-checked.json) and the bytes are the same: a bundle is patched by build_prefab_patch.patch_bundle
from the same stock bytes, whichever way they were fetched.

Which bundles to look at. The whole catalog is 6 GB, so only the likely ones are downloaded:

  * the bundles named in the previous menus / images manifests (prefab-patch.zip and
    prefab-images.zip of patch-latest, or a build folder's manifest.json), and
  * every bundle whose (name, content hash) is not in the previous catalog - what the update
    added or changed. A new prefab or a re-drawn texture is always one of these.

The previous catalog is the newest other catalog_*.json this script kept in --stock-dir (it keeps
each build's), or --prev-catalog. With neither it stops: pass --full-scan once to download and read
every bundle (slow, 6 GB), or --prev-catalog to name one.

A texture PNG that lands in no scanned bundle is listed at the end (TitleLogo_01 is expected: it
lives in the in-app bundle). A new PNG for an old bundle that nothing else changed is the one case
this misses; --full-scan finds it.

    py -I -X utf8 tools/prefab-patch/build_pc_prefabs.py --base-url <…/AssetBundle/StandaloneWindows64>
        --translation-cache <cache json> --prev-manifest prefab-patch.zip prefab-images.zip
        [--prefab-map ...] [--textures ...] [--out build/prefab-patch-en]
"""
import argparse
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
import build_prefab_patch as bpp  # noqa: E402
import unityfs  # noqa: E402
from build_ios_patch import catalog_bundles, fetch  # noqa: E402
from textures import DEFAULT_DIR as TEXTURE_DIR, texture_files  # noqa: E402


def names_of_manifest(path):
    """Bundle name folders listed in a manifest: prefab-*.zip, a manifest.json, or a build folder."""
    if os.path.isdir(path):
        path = os.path.join(path, "manifest.json")
    if path.lower().endswith(".zip"):
        raw = zipfile.ZipFile(path).read("manifest.json")
    else:
        raw = open(path, "rb").read()
    data = json.loads(raw.decode("utf-8-sig"))
    if isinstance(data, dict):
        data = [data]
    return {r["rel"].split("/")[0] for r in data}


def load_catalog(base, stock_dir):
    h = fetch(base + "/catalog_ja.hash").decode().strip()
    if not re.fullmatch(r"[0-9a-f]{32}", h):
        raise SystemExit(f"{base}/catalog_ja.hash is not a catalog hash: {h[:40]!r}")
    cdir = os.path.join(stock_dir, "catalogs")
    path = os.path.join(cdir, f"catalog_{h}.json")
    return h, json.loads(fetch(base + "/catalog_ja.json", path)), path


def previous_catalog(stock_dir, current_hash, explicit):
    path = explicit
    if not path:
        cdir = os.path.join(stock_dir, "catalogs")
        found = [os.path.join(cdir, f) for f in os.listdir(cdir)
                 if re.fullmatch(r"catalog_[0-9a-f]{32}\.json", f) and current_hash not in f] if os.path.isdir(cdir) else []
        path = max(found, key=os.path.getmtime) if found else None
    return (path, json.load(open(path, encoding="utf-8"))) if path else (None, None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True,
                    help="https://mushokutensei-coe-jp.akamaized.net/production/client/<build>/<unity>/AssetBundle/StandaloneWindows64")
    ap.add_argument("--translation-cache", required=True)
    ap.add_argument("--prefab-map", default=os.path.join(REPO, "translations", "en", "prefab", "ui-prefab.json"))
    ap.add_argument("--textures", default=TEXTURE_DIR, help='English texture PNGs ("" = text only)')
    ap.add_argument("--prev-manifest", nargs="*", default=[],
                    help="menus/images manifests of the previous build: prefab-*.zip, manifest.json or a build folder")
    ap.add_argument("--prev-catalog", help="the previous build's catalog_ja.json (default: the newest other one in --stock-dir)")
    ap.add_argument("--full-scan", action="store_true", help="download and read every bundle of the catalog (6 GB)")
    ap.add_argument("--stock-dir", default=os.path.join(REPO, "build", "pc-stock"), help="download cache")
    ap.add_argument("--out", default=os.path.join(REPO, "build", "prefab-patch"))
    ap.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    a = ap.parse_args()
    base = a.base_url.rstrip("/")
    m = re.search(r"/client/([^/]+)/([^/]+)/AssetBundle/StandaloneWindows64$", base)
    if not m:
        raise SystemExit("--base-url must end in /client/<build>/<unity>/AssetBundle/StandaloneWindows64")
    for p in (a.translation_cache, a.prefab_map):
        if not os.path.exists(p):
            raise SystemExit(f"{p} is missing")

    cat_hash, catalog, _ = load_catalog(base, a.stock_dir)
    cat = catalog_bundles(catalog)
    checked = bpp.crc_checked_bundles(catalog)
    if not checked:
        raise SystemExit("no m_UseCrcForCachedBundles entries in the catalog: its layout changed; refusing to "
                         "patch bundles that may be CRC-checked")
    print(f"catalog {cat_hash}: {len(cat)} bundles, {len(checked)} CRC-checked", flush=True)

    if a.full_scan:
        cand = set(cat)
        why = "full scan"
    else:
        prev_path, prev = previous_catalog(a.stock_dir, cat_hash, a.prev_catalog)
        if prev is None:
            raise SystemExit("no previous catalog to tell what the update changed: pass --prev-catalog "
                             "<catalog_ja.json of the previous build>, or --full-scan")
        old = {(n, v["hash"]) for n, v in catalog_bundles(prev).items()}
        changed = {n for n, v in cat.items() if (n, v["hash"]) not in old}
        named = set()
        for p in a.prev_manifest:
            named |= names_of_manifest(p)
        if not named:
            raise SystemExit("no previous menus/images manifest named (--prev-manifest): the list of bundles that "
                             "carry text would be empty")
        cand = (named | changed) & set(cat)
        why = (f"{len(named)} named by the previous manifests, {len(changed)} new or changed since "
               f"{os.path.basename(prev_path)}; {len(named - set(cat))} named ones are gone from the catalog")
    cand = sorted(cand)
    print(f"{len(cand)} bundles to read ({why}), {sum(cat[n]['size'] for n in cand) / 1e6:.0f} MB", flush=True)

    # stock bundles into a temp tree with the cache layout: <name>/<hash>/__data
    tree = os.path.join(a.stock_dir, "tree", cat_hash)

    def get(n):
        e = cat[n]
        dst = os.path.join(tree, n, e["hash"], "__data")
        if os.path.exists(dst):
            return n, dst
        data = fetch(base + "/" + e["file"])
        if len(data) != e["size"] and e["size"]:
            raise SystemExit(f"{e['file']}: {len(data)} bytes, the catalog says {e['size']}")
        if e["crc"] and unityfs.crc(data) != e["crc"]:
            raise SystemExit(f"{e['file']}: stock CRC {unityfs.crc(data):08x} is not the catalog's {e['crc']:08x}")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst + ".part", "wb") as f:
            f.write(data)
        os.replace(dst + ".part", dst)
        return n, dst

    with ThreadPoolExecutor(8) as ex:  # many small files from a CDN in Japan: the time is in round trips
        paths = dict(ex.map(get, cand))

    todo = [p for n, p in paths.items() if n not in checked and cat[n]["hash"] not in checked]
    kept = [p for n, p in paths.items() if n in checked or cat[n]["hash"] in checked]
    os.makedirs(a.out, exist_ok=True)
    rel_of = lambda p: "/".join(p.replace("\\", "/").split("/")[-3:])  # noqa: E731
    json.dump(sorted(rel_of(p) for p in kept), open(os.path.join(a.out, "crc-checked.json"), "w"), indent=1)

    manifest, untranslated = [], set()
    tex_names = set(texture_files(a.textures))
    print(f"{len(todo)} bundles to patch, {len(kept)} left stock (the game CRC-checks them), "
          f"{len(tex_names)} English textures", flush=True)
    # a previous run's output must not leave bundles the new run did not write
    for r in manifest_leftovers(a.out):
        os.remove(r)
    with ProcessPoolExecutor(a.workers, initializer=bpp._init,
                             initargs=(a.translation_cache, a.prefab_map, a.textures)) as ex:
        futs = [ex.submit(bpp.patch_bundle, p, rel_of(p)) for p in todo]
        for fu in as_completed(futs):
            r = fu.result()
            if not r:
                continue
            untranslated.update(r.pop("untranslated"))
            if r["changed"] or r["textures"]:
                dst = os.path.join(a.out, *r["rel"].split("/"))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                open(dst, "wb").write(r.pop("data"))
                manifest.append(r)
    manifest.sort(key=lambda r: r["rel"])
    json.dump(manifest, open(os.path.join(a.out, "manifest.json"), "w"), indent=1)
    json.dump(sorted(untranslated), open(os.path.join(a.out, "untranslated.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    json.dump({"client_build": m.group(1), "unity": m.group(2), "catalog_hash": cat_hash, "scanned": len(cand),
               "full_scan": a.full_scan},
              open(os.path.join(a.out, "source.json"), "w"), indent=1)
    written = {t for r in manifest for t in r["textures"]}
    print(len(manifest), "bundles,", sum(r["changed"] for r in manifest), "text fields,",
          sum(len(r["textures"]) for r in manifest), "textures;",
          len(untranslated), "strings left untranslated (untranslated.json)")
    if tex_names - written:
        print(len(tex_names - written), "textures not in any patched bundle:", ", ".join(sorted(tex_names - written)))


def manifest_leftovers(out):
    """Bundle files an earlier run wrote into --out (the tree is rebuilt from scratch)."""
    found = []
    for root, _, files in os.walk(out):
        found += [os.path.join(root, f) for f in files if f == "__data"]
    return found


if __name__ == "__main__":
    main()

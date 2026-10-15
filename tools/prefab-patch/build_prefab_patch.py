"""Write English into the UI prefabs of the cached Addressables bundles (PC).

Every bundle of the current catalog in the Unity cache is scanned for Japanese
TextMeshPro/uGUI `m_text`; the translated bundles are written, mirroring the
cache layout, to <out>/<name-hash>/<content-hash>/__data with manifest.json
(source and patched md5 per bundle) for tools/pc/Install-PrefabPatch.ps1.
Only the text objects change; every other object stays byte-identical and the
original block compression (LZ4HC) is kept. These bundles are loaded without
a cached-CRC check (m_UseCrcForCachedBundles is false for all of them).

  python -I -X utf8 build_prefab_patch.py --translation-cache translation_cache.json [--out DIR]

Japanese with no translation is left as is and listed in <out>/untranslated.json:
add those lines to translations/en/prefab/ui-prefab.json and rebuild.
"""
import argparse
import glob
import hashlib
import json
import os
import re
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402
from prefab_text import CJK, Translator, replace, texts  # noqa: E402

REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
_tr = None


def _init(cache_json, prefab_map):
    global _tr
    _tr = Translator(cache_json, prefab_map)


def patch_bundle(path, rel):
    import UnityPy
    src = open(path, "rb").read()
    try:
        env = UnityPy.load(src)
    except Exception:
        return None
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
    if not found:
        return None
    mapping = _tr.build(found)
    changed = 0
    for obj, tree in trees:
        n = replace(tree, mapping)
        if n:
            obj.save_typetree(tree)
            changed += n
    res = {"rel": rel, "changed": changed, "untranslated": sorted(set(found) - set(mapping))}
    if changed:
        data = env.file.save(packer="original")
        res.update(src_md5=hashlib.md5(src).hexdigest(), out_md5=hashlib.md5(data).hexdigest(),
                   src_size=len(src), out_size=len(data))
        res["data"] = data
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--translation-cache", required=True)
    ap.add_argument("--prefab-map", default=os.path.join(REPO, "translations", "en", "prefab", "ui-prefab.json"))
    ap.add_argument("--cache", help="Unity cache folder (…\\LocalLow\\Unity\\GREE Entertainment_クロエコ)")
    ap.add_argument("--catalog", help="Addressables catalog json (default: newest cached one)")
    ap.add_argument("--out", default=os.path.join(REPO, "build", "prefab-patch"))
    ap.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    a = ap.parse_args()

    cache = a.cache or paths.cache_dir()
    ids = json.load(open(a.catalog or paths.newest_catalog(), encoding="utf-8"))["m_InternalIds"]
    current = {m.group(1) for x in ids for m in [re.search(r"_([0-9a-f]{32})\.bundle$", x)] if m}
    bundles = [p for p in glob.glob(os.path.join(cache, "*", "*", "__data"))
               if os.path.basename(os.path.dirname(p)) in current]
    print(len(bundles), "cached bundles in the current catalog", flush=True)

    os.makedirs(a.out, exist_ok=True)
    manifest, untranslated = [], set()
    with ProcessPoolExecutor(a.workers, initializer=_init, initargs=(a.translation_cache, a.prefab_map)) as ex:
        futs = []
        for p in bundles:
            rel = "/".join(p.replace("\\", "/").split("/")[-3:])
            futs.append(ex.submit(patch_bundle, p, rel))
        for fu in as_completed(futs):
            r = fu.result()
            if not r:
                continue
            untranslated.update(r.pop("untranslated"))
            if r["changed"]:
                dst = os.path.join(a.out, *r["rel"].split("/"))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                open(dst, "wb").write(r.pop("data"))
                manifest.append(r)
    manifest.sort(key=lambda r: r["rel"])
    json.dump(manifest, open(os.path.join(a.out, "manifest.json"), "w"), indent=1)
    json.dump(sorted(untranslated), open(os.path.join(a.out, "untranslated.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(len(manifest), "bundles,", sum(r["changed"] for r in manifest), "text fields;",
          len(untranslated), "strings left untranslated (untranslated.json)")


if __name__ == "__main__":
    main()

"""Write English into the UI prefabs of the cached Addressables bundles (PC).

Every bundle of the current catalog in the Unity cache is scanned for Japanese
TextMeshPro/uGUI `m_text`; the translated bundles are written, mirroring the
cache layout, to <out>/<name-hash>/<content-hash>/__data with manifest.json
(source and patched md5 per bundle) for tools/pc/Install-PrefabPatch.ps1.
Only the text objects change; every other object stays byte-identical and the
original block compression (LZ4HC) is kept.

The same pass writes the English textures (translations/en/textures/<name>.png,
see textures.py): every cached Texture2D with that name is re-encoded in its
own format and size, and the manifest lists them per bundle ("textures"). A
bundle that carries both text and textures gets one file with both.

Bundles whose catalog entry has m_UseCrcForCachedBundles set are left alone and
listed in <out>/crc-checked.json: the game verifies those against the catalog's
CRC when it loads them from the cache, so a rewritten file would fail with
"Failed to acquire resources". (Only the language bundle and 76 others are
marked that way; none of them carries UI text today, but the flag is a property
of the catalog, not of these bundles.)

  python -I -X utf8 build_prefab_patch.py --translation-cache translation_cache.json [--out DIR]
      [--textures DIR]   (default translations/en/textures; --textures "" = text only)

Japanese with no translation is left as is and listed in <out>/untranslated.json:
add those lines to translations/en/prefab/ui-prefab.json and rebuild.
"""
import argparse
import base64
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
from textures import DEFAULT_DIR as TEXTURE_DIR, set_textures, texture_files  # noqa: E402

REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
_tr = None
_tex = {}


def _init(cache_json, prefab_map, textures_dir=None):
    global _tr, _tex
    _tr = Translator(cache_json, prefab_map)
    _tex = texture_files(textures_dir)


def bundle_hashes(path):
    """The two hashes in <name-hash>/<content-hash>/__data; the catalog names
    bundles by the second one, the cache folder uses the first."""
    parts = path.replace("\\", "/").split("/")
    return parts[-3], parts[-2]


def crc_checked_bundles(catalog_json):
    """Bundle hashes whose catalog entry has m_UseCrcForCachedBundles set.

    Those are verified against the catalog's CRC when the game loads them from
    the cache, so rewriting one breaks loading. The catalog keeps the per-bundle
    options in m_ExtraDataString (base64 of UTF-16 JSON objects)."""
    raw = catalog_json.get("m_ExtraDataString") or ""
    if not raw:
        return set()
    try:
        text = base64.b64decode(raw).decode("utf-16-le", "ignore")
    except (ValueError, TypeError):
        return set()
    out = set()
    for m in re.finditer(r'\{"m_Hash".*?"m_ClearOtherCachedVersionsWhenLoaded":(?:true|false)\}', text):
        try:
            entry = json.loads(m.group())
        except ValueError:
            continue
        if entry.get("m_UseCrcForCachedBundles") and entry.get("m_Crc"):
            name = entry.get("m_BundleName")
            if name:
                out.add(name)
    return out


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
    tex = set_textures(env, _tex)
    if not found and not tex:
        return None
    mapping = _tr.build(found) if found else {}
    changed = 0
    for obj, tree in trees:
        n = replace(tree, mapping)
        if n:
            obj.save_typetree(tree)
            changed += n
    res = {"rel": rel, "changed": changed, "textures": sorted(tex), "untranslated": sorted(set(found) - set(mapping))}
    if changed or tex:
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
    ap.add_argument("--textures", default=TEXTURE_DIR, help='English texture PNGs ("" = text only)')
    ap.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    a = ap.parse_args()

    cache = a.cache or paths.cache_dir()
    catalog_path = a.catalog or paths.newest_catalog()
    catalog = json.load(open(catalog_path, encoding="utf-8"))
    ids = catalog["m_InternalIds"]
    current = {m.group(1) for x in ids for m in [re.search(r"_([0-9a-f]{32})\.bundle$", x)] if m}
    checked = crc_checked_bundles(catalog)
    if not checked:
        raise SystemExit(
            f"no m_UseCrcForCachedBundles entries found in {catalog_path}: the catalog layout "
            "changed, or the wrong file was picked. Refusing to patch bundles that may be "
            "CRC-checked (pass --catalog with the catalog the game is using).")
    bundles, kept_stock = [], []
    for p in glob.glob(os.path.join(cache, "*", "*", "__data")):
        name, content = bundle_hashes(p)
        if content not in current:
            continue
        (kept_stock if (name in checked or content in checked) else bundles).append(p)
    print(len(bundles), "cached bundles in the current catalog;", len(kept_stock),
          "left stock (the game CRC-checks them)", flush=True)

    os.makedirs(a.out, exist_ok=True)
    json.dump(sorted("/".join(p.replace("\\", "/").split("/")[-3:]) for p in kept_stock),
              open(os.path.join(a.out, "crc-checked.json"), "w"), indent=1)
    manifest, untranslated = [], set()
    tex_names = set(texture_files(a.textures))
    print(len(tex_names), "English textures in", a.textures or "(none)", flush=True)
    with ProcessPoolExecutor(a.workers, initializer=_init,
                             initargs=(a.translation_cache, a.prefab_map, a.textures)) as ex:
        futs = []
        for p in bundles:
            rel = "/".join(p.replace("\\", "/").split("/")[-3:])
            futs.append(ex.submit(patch_bundle, p, rel))
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
    written = {t for r in manifest for t in r["textures"]}
    print(len(manifest), "bundles,", sum(r["changed"] for r in manifest), "text fields,",
          sum(len(r["textures"]) for r in manifest), "textures;",
          len(untranslated), "strings left untranslated (untranslated.json)")
    if tex_names - written:
        # in-app only (build_inapp.py writes those), or in a CRC-checked bundle
        print(len(tex_names - written), "textures not in any patched cache bundle:",
              ", ".join(sorted(tex_names - written)))
    if kept_stock:
        print(len(kept_stock), "bundles left stock because the game CRC-checks them (crc-checked.json)")


if __name__ == "__main__":
    main()

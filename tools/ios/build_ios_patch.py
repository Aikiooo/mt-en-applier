"""iOS patch: the English language pack, UI prefab text and redrawn images, as iOS bundles
the game downloads in place of its own.

An iOS app can't write into another app's files, so the patch goes in the way the game's
own data does: over the network. The game downloads its Addressables bundles from

    https://mushokutensei-coe-jp.akamaized.net/production/client/<build>/<unity>/AssetBundle/iOS/<name>_<hash>.bundle

and keeps them in its cache until the catalog names a new hash. A rewrite module for a
free iOS network app (Egern; the same file works in Shadowrocket, Surge and Loon)
answers the request for each patched bundle with a 302 to its copy on the `ios-latest`
release. Unity follows the redirect, checks the CRC from the catalog, and caches the
English file under the stock hash, so the patch stays after the app is switched off,
until a game update replaces that bundle.

Every bundle has a download CRC in the iOS catalog, so each patched file keeps the stock
CRC (unityfs.forge, as build_inapp.py does). The language bundle also keeps the stock size
(build_locale_bundle.build). Which bundles carry prefab text or redrawn textures comes from
the PC manifests on patch-latest: their name folders (m_BundleName) are the same on iOS.

    python -I -X utf8 tools/ios/build_ios_patch.py --base-url <…/AssetBundle/iOS> --release-dir <patch-latest files>
        [--out build/ios] [--release-url https://github.com/Aikiooo/mt-en-applier/releases/download/ios-latest]

<patch-latest files> holds language-ja_en.bundle, translation_cache.json, prefab-patch.zip and
prefab-images.zip (`gh release download patch-latest -p …`). The AES key is the PC one
(the same on every platform): found from the PC global-metadata.dat (--metadata), as
build_locale_bundle.py does, or given with --key/--iv.

Output (<out>): every patched bundle under its CDN file name, the rewrite module in
Egern's format (mt-en-ios.yaml) and Surge's (mt-en-ios.sgmodule: Shadowrocket, Surge,
Loon), ios-manifest.json. Upload all of it to the ios-latest release
(tools/ios/Publish-IosPatch.ps1).
"""
import argparse
import base64
import hashlib
import json
import os
import re
import sys
import urllib.request
import zipfile
from concurrent.futures import ProcessPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "prefab-patch"))
import build_locale_bundle  # noqa: E402
import mtcrypto  # noqa: E402
import unityfs  # noqa: E402
from prefab_text import CJK, Translator, replace, texts  # noqa: E402
from textures import set_textures, texture_files  # noqa: E402

CDN_HOST = "mushokutensei-coe-jp.akamaized.net"
RELEASE_URL = "https://github.com/Aikiooo/mt-en-applier/releases/download/ios-latest"
IOS_TARGET = 9          # BuildTarget.iOS, in the serialized file header
OPTS = re.compile(r'\{"m_Hash".*?"m_ClearOtherCachedVersionsWhenLoaded":(?:true|false)\}')


# ---------------------------------------------------------------- catalog

def catalog_bundles(catalog):
    """{name folder (m_BundleName): {"file", "hash", "crc", "size"}} from an Addressables catalog."""
    by_hash = {}
    for x in catalog["m_InternalIds"]:
        m = re.search(r"([^\\/]+_([0-9a-f]{32})\.bundle)$", x)
        if m:
            by_hash[m.group(2)] = m.group(1)
    raw = base64.b64decode(catalog["m_ExtraDataString"])
    # the options are UTF-16 JSON strings at arbitrary byte offsets: read both alignments
    text = raw.decode("utf-16-le", "ignore") + raw[1:].decode("utf-16-le", "ignore")
    out = {}
    for m in OPTS.finditer(text):
        try:
            e = json.loads(m.group())
        except ValueError:
            continue
        f = by_hash.get(e["m_Hash"])
        if f:
            out[e["m_BundleName"]] = {"file": f, "hash": e["m_Hash"], "crc": e["m_Crc"], "size": e["m_BundleSize"]}
    return out


def fetch(url, dst=None):
    if dst and os.path.exists(dst):
        return open(dst, "rb").read()
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    if dst:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst + ".part", "wb").write(data)
        os.replace(dst + ".part", dst)
    return data


# ---------------------------------------------------------------- bundles

def target_platform(data):
    import UnityPy
    sf = next(f for f in UnityPy.load(data).file.files.values() if hasattr(f, "objects"))
    return sf.target_platform


def build_language(stock, english, key, iv):
    """The English tables in the iOS stock language bundle, at the stock size and CRC."""
    _, s_assets = mtcrypto.text_assets(stock)
    ja = {n: mtcrypto.decrypt(s, key, iv) for n, (s, _) in s_assets.items() if n.startswith("e_")}
    _, e_assets = mtcrypto.text_assets(english)
    en = {n: mtcrypto.decrypt(s, key, iv) for n, (s, _) in e_assets.items() if n.startswith("e_")}
    if set(ja) != set(en):
        raise SystemExit(f"language tables differ: iOS only {sorted(set(ja) - set(en))}, "
                         f"English only {sorted(set(en) - set(ja))}")
    rows = lambda t: [r.split("\t", 1)[0] for r in t.split("\n")[1:] if r]  # noqa: E731
    changed = [n for n in ja if rows(ja[n]) != rows(en[n])]
    if changed:
        raise SystemExit(f"row ids differ in {len(changed)} tables ({changed[:5]}): the English patch "
                         "is for another game version; rebuild it for this one first")
    data, _ = build_locale_bundle.build(stock, key, iv, en)
    _, check = mtcrypto.text_assets(data)
    for n, text in en.items():
        assert mtcrypto.decrypt(check[n][0], key, iv) == text, n
    assert len(data) == len(stock) and unityfs.crc(data) == unityfs.crc(stock)
    assert target_platform(data) == IOS_TARGET
    return data


def forge_crc(data, target):
    """data rebuilt with its decompressed-stream CRC set to target. The 4 forged bytes go in
    padding between two serialized objects, or else past the end of the last node; Unity
    reads objects and resource data by offset, so neither is ever read."""
    import UnityPy
    info = unityfs.parse(data)
    sf = next(f for f in UnityPy.load(data).file.files.values() if hasattr(f, "objects"))
    node0 = next(off for off, _, _, name in info["nodes"] if not name.endswith((b".resS", b".resource")))
    objs = sorted(sf.objects.values(), key=lambda o: o.byte_start)
    for a, b in zip(objs, objs[1:]):
        end = a.byte_start + a.byte_size
        if b.byte_start - end >= 4 and info["stream"][node0 + end:node0 + end + 4] == b"\0\0\0\0":
            return unityfs.build(info, unityfs.forge(info["stream"], node0 + end, target))
    last = max(range(len(info["nodes"])), key=lambda i: info["nodes"][i][0] + info["nodes"][i][1])
    off, sz, fl, name = info["nodes"][last]
    assert off + sz == len(info["stream"]), "stream has bytes past the last node"
    nodes = [n if i != last else (off, sz + 4, fl, name) for i, n in enumerate(info["nodes"])]
    stream = info["stream"] + b"\0\0\0\0"
    return unityfs.build(dict(info, nodes=nodes), unityfs.forge(stream, len(stream) - 4, target))


_tr = None
_tex = {}


def _init(cache, prefab_map, tex_dir):
    global _tr, _tex
    _tr = Translator(cache, prefab_map)
    _tex = texture_files(tex_dir)


def patch_ui(stock_path, crc):
    """English prefab text and textures in one iOS bundle, CRC forged back to the catalog's."""
    import UnityPy
    src = open(stock_path, "rb").read()
    if unityfs.crc(src) != crc:
        return {"error": "stock CRC %08x is not the catalog's %08x" % (unityfs.crc(src), crc)}
    env = UnityPy.load(src)
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
    mapping = _tr.build(found) if found else {}
    changed = 0
    for obj, tree in trees:
        n = replace(tree, mapping)
        if n:
            obj.save_typetree(tree)
            changed += n
    res = {"text_fields": changed, "textures": sorted(tex), "untranslated": sorted(set(found) - set(mapping))}
    if changed or tex:
        data = forge_crc(env.file.save(packer="original"), crc)
        assert unityfs.crc(data) == crc
        UnityPy.load(data)
        res["data"] = data
    return res


# ---------------------------------------------------------------- module

def module_text(files, release_url, built_at):
    """Surge-format rewrite module (Egern, Shadowrocket, Surge and Loon read it)."""
    host = re.escape(CDN_HOST)
    lines = [
        "#!name=Mushoku Tensei English Patch (iOS)",
        "#!desc=Unofficial fan English patch for Mushoku Tensei: Chronicle of Echoes. "
        "Sends the game's Japanese text and image bundles to their English copies. Built " + built_at + ".",
        "#!homepage=https://mtcoe.com/#/en-patch",
        "",
        "[URL Rewrite]",
    ]
    for f in sorted(files):
        lines.append(f"^https://{host}/production/client/[^/]+/[^/]+/AssetBundle/iOS/{re.escape(f)}$ "
                     f"{release_url}/{f} 302")
    lines += ["", "[MITM]", f"hostname = %APPEND% {CDN_HOST}", ""]
    return "\n".join(lines)


def egern_text(files, release_url, built_at):
    """The same rewrites as an Egern module (YAML)."""
    host = re.escape(CDN_HOST)
    lines = [
        "name: Mushoku Tensei English Patch (iOS)",
        "description: Unofficial fan English patch for Mushoku Tensei Chronicle of Echoes, built " + built_at,
        "url_rewrites:",
    ]
    for f in sorted(files):
        lines += [f"  - match: '^https://{host}/production/client/[^/]+/[^/]+/AssetBundle/iOS/{re.escape(f)}$'",
                  f"    location: '{release_url}/{f}'",
                  "    status_code: 302"]
    lines += ["mitm:", "  hostnames:", "    includes:", f"      - {CDN_HOST}", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------- main

def pc_bundle_names(zips):
    names = set()
    for p in zips:
        for r in json.loads(zipfile.ZipFile(p).read("manifest.json").decode("utf-8-sig")):
            names.add(r["rel"].split("/")[0])
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True, help=f"https://{CDN_HOST}/production/client/<build>/<unity>/AssetBundle/iOS")
    ap.add_argument("--release-dir", required=True, help="folder with the patch-latest files (see above)")
    ap.add_argument("--out", default=os.path.join(REPO, "build", "ios"))
    ap.add_argument("--stock-dir", default=os.path.join(REPO, "build", "ios-stock"), help="download cache")
    ap.add_argument("--release-url", default=RELEASE_URL)
    ap.add_argument("--prefab-map", default=os.path.join(REPO, "translations", "en", "prefab", "ui-prefab.json"))
    ap.add_argument("--textures", default=os.path.join(REPO, "translations", "en", "textures"))
    ap.add_argument("--metadata", help="global-metadata.dat of the PC game (the key is the same on every platform)")
    ap.add_argument("--key")
    ap.add_argument("--iv")
    ap.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    a = ap.parse_args()
    base = a.base_url.rstrip("/")
    rel = lambda n: os.path.join(a.release_dir, n)  # noqa: E731
    os.makedirs(a.out, exist_ok=True)

    m = re.search(r"/client/([^/]+)/([^/]+)/AssetBundle/iOS$", base)
    if not m:
        raise SystemExit("--base-url must end in /client/<build>/<unity>/AssetBundle/iOS")
    catalog_hash = fetch(base + "/catalog_ja.hash").decode().strip()
    catalog = json.loads(fetch(base + "/catalog_ja.json", os.path.join(a.stock_dir, catalog_hash, "catalog_ja.json")))
    cat = catalog_bundles(catalog)
    stock_dir = os.path.join(a.stock_dir, catalog_hash)
    print(f"catalog {catalog_hash}: {len(cat)} bundles", flush=True)

    # 1. language pack
    lang = next((k for k, v in cat.items() if v["file"].startswith("language-ja_assets_all_")), None)
    if not lang:
        raise SystemExit("no language-ja bundle in the catalog")
    lf = cat[lang]["file"]
    stock = fetch(base + "/" + lf, os.path.join(stock_dir, lf))
    if target_platform(stock) != IOS_TARGET:
        raise SystemExit(f"{lf} is not an iOS bundle")
    english = open(rel("language-ja_en.bundle"), "rb").read()
    if a.key and a.iv:
        key, iv = bytes.fromhex(a.key), bytes.fromhex(a.iv)
    elif a.metadata:
        key, iv, _, _ = mtcrypto.find_keys(a.metadata, rel("language-ja_en.bundle"))
    else:
        raise SystemExit("pass --metadata <PC global-metadata.dat> or --key/--iv (hex): the AES key of the tables")
    lang_data = build_language(stock, english, key, iv)
    open(os.path.join(a.out, lf), "wb").write(lang_data)
    manifest = [{"file": lf, "bundle": lang, "kind": "language", "crc": "%08x" % cat[lang]["crc"],
                 "size": len(lang_data), "src_md5": hashlib.md5(stock).hexdigest(),
                 "out_md5": hashlib.md5(lang_data).hexdigest()}]
    print(f"language: {lf} ({len(lang_data)} B, CRC {cat[lang]['crc']:08x})", flush=True)

    # 2. UI prefab text + textures
    want = sorted(pc_bundle_names([rel("prefab-patch.zip"), rel("prefab-images.zip")]))
    missing = [n for n in want if n not in cat]
    want = [n for n in want if n in cat]
    for n in want:
        fetch(base + "/" + cat[n]["file"], os.path.join(stock_dir, cat[n]["file"]))
    print(f"ui: {len(want)} bundles ({len(missing)} of the PC list not on iOS)", flush=True)
    untranslated, errors = set(), []
    with ProcessPoolExecutor(a.workers, initializer=_init,
                             initargs=(rel("translation_cache.json"), a.prefab_map, a.textures)) as ex:
        futs = {ex.submit(patch_ui, os.path.join(stock_dir, cat[n]["file"]), cat[n]["crc"]): n for n in want}
        for fu in as_completed(futs):
            n, r = futs[fu], fu.result()
            if "error" in r:
                errors.append(f"{cat[n]['file']}: {r['error']}")
                continue
            untranslated.update(r["untranslated"])
            if "data" in r:
                f = cat[n]["file"]
                open(os.path.join(a.out, f), "wb").write(r["data"])
                src = open(os.path.join(stock_dir, f), "rb").read()
                manifest.append({"file": f, "bundle": n, "kind": "ui", "crc": "%08x" % cat[n]["crc"],
                                 "size": len(r["data"]), "src_md5": hashlib.md5(src).hexdigest(),
                                 "out_md5": hashlib.md5(r["data"]).hexdigest(),
                                 "text_fields": r["text_fields"], "textures": r["textures"]})
    if errors:
        raise SystemExit("stock bundles that don't match the catalog:\n  " + "\n  ".join(errors[:10]))

    # 3. module + manifest
    import datetime
    built_at = datetime.datetime.now().strftime("%Y-%m-%d")
    manifest.sort(key=lambda r: (r["kind"] != "language", r["file"]))
    files = [r["file"] for r in manifest]
    open(os.path.join(a.out, "mt-en-ios.sgmodule"), "w", encoding="utf-8", newline="\n").write(
        module_text(files, a.release_url.rstrip("/"), built_at))
    open(os.path.join(a.out, "mt-en-ios.yaml"), "w", encoding="utf-8", newline="\n").write(
        egern_text(files, a.release_url.rstrip("/"), built_at))
    ui = [r for r in manifest if r["kind"] == "ui"]
    summary = {"built_at": built_at, "client_build": m.group(1), "unity": m.group(2), "catalog_hash": catalog_hash,
               "bundles": len(manifest), "text_fields": sum(r["text_fields"] for r in ui),
               "textures": len({t for r in ui for t in r["textures"]}),
               "untranslated": sorted(untranslated), "files": manifest}
    json.dump(summary, open(os.path.join(a.out, "ios-manifest.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps({k: v for k, v in summary.items() if k not in ("files", "untranslated")}
                     | {"untranslated": len(untranslated),
                        "size_mb": round(sum(r["size"] for r in manifest) / 1e6, 1)}, indent=1))


if __name__ == "__main__":
    main()

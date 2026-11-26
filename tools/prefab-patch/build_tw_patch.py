"""Build all Taiwan client (com.cayenne.mtr) Android patch artifacts:

  - __data.tw                 English language bundle (exact TW stock size + forged CRC, 0 reverts)
  - __data.tw.fr              French language bundle (UnityPy full repack + forged CRC, 0 reverts)
  - translation_cache.tw.<loc>.json   zh-TW -> <loc> cache + (table, id) hand disambiguations
  - android-prefabs-tw-<loc>.zip      243 TW UI prefab bundles (TMP text translated, forged CRC)
  - android-images-tw-<loc>.zip       98 TW image bundles (122 ASTC textures + TMP text, forged CRC)
  - tw-build-summary.json             sizes, MD5s, CRCs, coverage & residual CJK verification

Sources (read-only):
  - TW device data pull (global-metadata.dat, Addressables catalog JSON, UnityCache/Shared/)
  - TW base.apk (inapp_assets_all.bundle carries the exact Language/ja/* mirror of all 30,927 TW rows)
  - JP Android stock bundles + catalog_ja.json (for JP <-> TW MonoBehaviour path_id alignment)
  - mt_en_applier/translations/{en,fr}/ (source, hand, prefab, textures, tw overlays)

Usage:
  python -I -X utf8 tools/prefab-patch/build_tw_patch.py [--locale en fr] [--out build/tw]
"""
import argparse
import collections
import glob
import hashlib
import json
import os
import re
import sys
import zipfile
from concurrent.futures import ProcessPoolExecutor, as_completed

import UnityPy

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "tools", "ios"))

import build_locale_bundle  # noqa: E402
import mtcrypto  # noqa: E402
import unityfs  # noqa: E402
from build_android_prefabs import ANDROID_TARGET, crc_checked, write_zip  # noqa: E402
from build_ios_patch import catalog_bundles, forge_crc, target_platform  # noqa: E402
from prefab_text import CJK, PLACEHOLDER, _from_cache, filler, replace, texts  # noqa: E402
from textures import set_textures, texture_files  # noqa: E402

TW_LANG_GUID = "513353b6ad174a743e3dbc22a70182c7"
KANA = re.compile(r"[\u3040-\u30ff]")
PREFIX_TAG = re.compile(r"^\((?:zhhk|en|zhcn|ko)\)")
HASH_SUFFIX = re.compile(r"_[0-9a-f]{32}\.bundle$")

DEFAULT_TW_ROOT = r"D:\projects\mushoku-tensei\mushoku_apk\tw\device_data_pull\com.cayenne.mtr"
DEFAULT_TW_APK = r"D:\projects\mushoku-tensei\mushoku_apk\tw\from_device_backup\base.apk"
DEFAULT_JP_STOCK = os.path.join(REPO, "build", "android-stock", "a5585012934a04ed508870205710cb79")
DEFAULT_JP_PREFABS_ZIP = os.path.join(REPO, "build", "android-prefabs-en.zip")
DEFAULT_JP_IMAGES_ZIP = os.path.join(REPO, "build", "android-images-en.zip")


def md5(b):
    return hashlib.md5(b).hexdigest()


def logical_name(filename):
    return HASH_SUFFIX.sub("", filename)


def find_tw_catalog(tw_root):
    addr_dir = os.path.join(tw_root, "files", "com.unity.addressables")
    cands = [os.path.join(addr_dir, f) for f in os.listdir(addr_dir) if f.endswith(".json")]
    if not cands:
        raise SystemExit(f"no catalog json found under {addr_dir}")
    return max(cands, key=os.path.getsize)


def load_locale_maps(loc):
    """Load canonical EN maps overlaid with `loc` (matching Build-TranslationCache.ps1)."""
    root = os.path.join(REPO, "translations")

    def read_one(code):
        cache = {}
        src_dir = os.path.join(root, code, "source")
        if os.path.isdir(src_dir):
            for p in sorted(glob.glob(os.path.join(src_dir, "*.json"))):
                cache.update(json.load(open(p, encoding="utf-8")))
        hand = {}
        hand_dir = os.path.join(root, code, "hand")
        if os.path.isdir(hand_dir):
            for p in sorted(glob.glob(os.path.join(hand_dir, "*.json"))):
                hand[os.path.splitext(os.path.basename(p))[0]] = json.load(open(p, encoding="utf-8"))
        return cache, hand

    cache, hand = read_one("en")
    if loc != "en":
        oc, oh = read_one(loc)
        cache.update(oc)
        for t, m in oh.items():
            hand.setdefault(t, {}).update(m)

    tw_dir = os.path.join(root, loc, "tw")
    tw_extra = json.load(open(os.path.join(tw_dir, "tw-lang-extra.json"), encoding="utf-8"))
    tw_prefab = json.load(open(os.path.join(tw_dir, "ui-prefab-zhtw.json"), encoding="utf-8"))
    jp_prefab = json.load(open(os.path.join(root, loc, "prefab", "ui-prefab.json"), encoding="utf-8"))
    tex_dir = os.path.join(root, loc, "textures")
    return cache, hand, tw_extra, jp_prefab, tw_prefab, tex_dir


def parse_tsv(text):
    norm = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = norm.split("\n")
    header = lines[0]
    cols = len(header.split("\t"))
    need = cols - 1
    rows = []
    for ln in lines[1:]:
        if not ln.strip():
            continue
        parts = ln.split("\t")
        rid = parts[0]
        vals = parts[1:]
        if len(vals) < need:
            vals += [""] * (need - len(vals))
        elif len(vals) > need:
            vals = vals[:need - 1] + ["\t".join(vals[need - 1:])]
        rows.append((rid, vals))
    return header, rows


def format_tsv(header, rows):
    out = [header]
    for rid, vals in rows:
        out.append(rid + "\t" + "\t".join(vals))
    return "\n".join(out)


def extract_tw_inapp_ja(apk_path, key, iv, tw_tables, en_ja_cache):
    """Extract the exact Japanese e_* tables from TW base.apk!/assets/aa/Android/inapp_assets_all.bundle."""
    with zipfile.ZipFile(apk_path) as z:
        raw = z.read("assets/aa/Android/inapp_assets_all.bundle")
    env = UnityPy.load(raw)
    copies = collections.defaultdict(list)
    for obj in env.objects:
        if obj.type.name != "TextAsset":
            continue
        name, script = mtcrypto.split_text_asset(obj.get_raw_data())
        if name in tw_tables and len(script) >= 16 and len(script) % 16 == 0:
            try:
                txt = mtcrypto.decrypt(script, key, iv)
            except Exception:
                continue
            if txt.startswith("id\t"):
                copies[name].append(txt)

    ja_tables = {}
    for name, cands in sorted(copies.items()):
        tw_txt = tw_tables.get(name, "")
        scored = []
        for txt in cands:
            lines = txt.splitlines()[1:]
            cells = [c.strip() for ln in lines for c in ln.split("\t")[1:] if c.strip()]
            tagged = sum(1 for c in cells[:50] if PREFIX_TAG.match(c))
            cache_hits = sum(1 for c in cells if c in en_ja_cache)
            kana_n = len(KANA.findall(txt))
            same_as_tw = 1 if txt == tw_txt else 0
            # Pure JA has 0 (zhhk)/(en) prefixes, highest ja_cache hit count, and highest kana count.
            scored.append((tagged == 0, cache_hits, kana_n, not same_as_tw, txt))
        scored.sort(key=lambda x: (x[0], x[1], x[2], x[3]), reverse=True)
        ja_tables[name] = scored[0][4]
    assert set(tw_tables).issubset(set(ja_tables)), (
        f"missing JA tables in inapp: {sorted(set(tw_tables) - set(ja_tables))}"
    )
    return ja_tables


def translate_cell_ja(ja_cell, ja_cache):
    s = ja_cell.strip()
    if not s:
        return None
    hit = ja_cache.get(s)
    if hit is None:
        return None
    lead = ja_cell[:len(ja_cell) - len(ja_cell.lstrip())]
    trail = ja_cell[len(ja_cell.rstrip()):]
    return lead + hit + trail


def translate_tw_tables(tw_tables, ja_tables, ja_cache, jp_hand, tw_extra):
    """Translate all 140 TW tables and build the zh-TW -> loc cache + hand map."""
    out_tables = {}
    zhtw_counts = collections.defaultdict(collections.Counter)
    row_resolved = {}  # (table, rid) -> translated last-col value when single text col
    stats = collections.Counter()
    leftover_cjk = []

    for name in sorted(tw_tables):
        tw_hdr, tw_rows = parse_tsv(tw_tables[name])
        _, ja_rows_list = parse_tsv(ja_tables[name])
        ja_by_id = {rid: vals for rid, vals in ja_rows_list}
        hand_tbl = jp_hand.get(name, {})

        new_rows = []
        for rid, tw_vals in tw_rows:
            ja_vals = ja_by_id.get(rid)
            out_vals = list(tw_vals)
            for ci, tw_cell in enumerate(tw_vals):
                if not tw_cell or tw_cell.isdigit():
                    continue
                is_last = (ci == len(tw_vals) - 1)
                translated = None
                if is_last and rid in hand_tbl:
                    translated = hand_tbl[rid]
                    stats["hand"] += 1
                if translated is None and ja_vals is not None and ci < len(ja_vals):
                    translated = translate_cell_ja(ja_vals[ci], ja_cache)
                    if translated is not None:
                        stats["ja_cache"] += 1
                if translated is None:
                    s = tw_cell.strip()
                    if s in tw_extra:
                        lead = tw_cell[:len(tw_cell) - len(tw_cell.lstrip())]
                        trail = tw_cell[len(tw_cell.rstrip()):]
                        translated = lead + tw_extra[s] + trail
                        stats["tw_extra"] += 1
                if translated is not None:
                    out_vals[ci] = translated
                    if CJK.search(tw_cell):
                        zhtw_counts[tw_cell.strip()][translated.strip()] += 1
                else:
                    if CJK.search(tw_cell):
                        stats["untranslated_cjk"] += 1
                        leftover_cjk.append((name, rid, ci, tw_cell))
                    else:
                        stats["kept_ascii"] += 1
            if len(out_vals) == 1 and out_vals[0] != tw_vals[0]:
                row_resolved[(name, rid)] = (tw_vals[0].strip(), out_vals[0])
            new_rows.append((rid, out_vals))
        out_tables[name] = format_tsv(tw_hdr, new_rows)

    # Build zh-TW -> loc cache (most common translation wins; tw_extra fills any remaining keys)
    tw_cache = {}
    for k, counter in sorted(zhtw_counts.items()):
        tw_cache[k] = counter.most_common(1)[0][0]
    for k, v in sorted(tw_extra.items()):
        tw_cache.setdefault(k, v)

    # Build hand disambiguations: every JP hand entry + every single-col row whose exact
    # translation differs from tw_cache[zhtw], so on-device AutoPatcher reproduces exact tables.
    tw_hand = collections.defaultdict(dict)
    for t, m in jp_hand.items():
        if t in out_tables:
            tw_hand[t].update(m)
    for (t, rid), (zhtw_s, exact_val) in row_resolved.items():
        if tw_cache.get(zhtw_s) != exact_val:
            tw_hand[t][rid] = exact_val

    tw_hand_sorted = {
        t: dict(sorted(m.items()))
        for t, m in sorted(tw_hand.items()) if m
    }
    return out_tables, dict(sorted(tw_cache.items())), tw_hand_sorted, stats, leftover_cjk


def build_tw_language_bundle(stock_bytes, key, iv, tables, exact_size=True):
    """Build TW language bundle: exact stock size + forged CRC if it fits, else grown + forged CRC."""
    stock_crc = unityfs.crc(stock_bytes)
    if exact_size:
        data, newlines = build_locale_bundle.build(stock_bytes, key, iv, tables)
        assert len(data) == len(stock_bytes), f"expected exact size {len(stock_bytes)}, got {len(data)}"
        mode = "exact_size"
    else:
        info, stream = build_locale_bundle.make_stream(stock_bytes, key, iv, tables, 0, stock_crc)
        data = build_locale_bundle.assemble(info, stream, 4096)
        newlines = 0
        mode = "grown_forged_crc"

    # Full round-trip verification of all 140 tables + CRC + Android target platform
    assert unityfs.crc(data) == stock_crc, f"CRC mismatch: {unityfs.crc(data):08x} != {stock_crc:08x}"
    assert target_platform(data) == ANDROID_TARGET, "not TargetPlatform.Android (13)"
    _, check = mtcrypto.text_assets(data)
    assert set(n for n in check if n.startswith("e_")) == set(tables)
    for n, expected in tables.items():
        got = mtcrypto.decrypt(check[n][0], key, iv)
        assert got == expected, f"round-trip mismatch in table {n}"
    return data, newlines, mode


# ---------------------------------------------------------------- prefab & image patching

def collect_path_id_pairs(jp_stock_path, tw_stock_path):
    """Align MonoBehaviour m_text fields between JP and TW stock bundles by path_id."""
    jp_texts = {}
    env_jp = UnityPy.load(jp_stock_path)
    for obj in env_jp.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        try:
            tree = obj.read_typetree()
        except Exception:
            continue
        ts = list(texts(tree))
        if ts:
            jp_texts[obj.path_id] = ts

    pairs = []
    env_tw = UnityPy.load(tw_stock_path)
    for obj in env_tw.objects:
        if obj.type.name != "MonoBehaviour" or obj.path_id not in jp_texts:
            continue
        try:
            tree = obj.read_typetree()
        except Exception:
            continue
        tw_ts = list(texts(tree))
        jp_ts = jp_texts[obj.path_id]
        if len(tw_ts) == len(jp_ts):
            for tw_s, jp_s in zip(tw_ts, jp_ts):
                if tw_s and jp_s and CJK.search(tw_s):
                    pairs.append((tw_s, jp_s))
    return pairs


class TwPrefabTranslator:
    """Layered translator for TW UI prefabs (hybrid untouched JA + localized zh-TW)."""

    def __init__(self, ja_cache, jp_prefab, zhtw_cache, tw_prefab, path_id_zhtw_to_loc):
        self.ja_cache = ja_cache
        self.jp_prefab = jp_prefab
        self.zhtw_cache = zhtw_cache
        self.tw_prefab = tw_prefab
        self.path_id_map = path_id_zhtw_to_loc

    def build(self, cjk_strings):
        out = {}
        for s in sorted(set(cjk_strings)):
            hit = None
            if s in self.tw_prefab:
                hit = self.tw_prefab[s]
            elif s.strip() in self.tw_prefab:
                hit = _from_cache(self.tw_prefab, s)
            if hit is None:
                hit = _from_cache(self.ja_cache, s)
            if hit is None and s in self.jp_prefab:
                hit = self.jp_prefab[s]
            if hit is None:
                hit = _from_cache(self.zhtw_cache, s)
            if hit is None and s in self.path_id_map:
                hit = self.path_id_map[s]
            if hit is None and s.strip() in self.path_id_map:
                hit = _from_cache(self.path_id_map, s)
            if hit is None and PLACEHOLDER.search(s):
                hit = filler(s)
            if hit is not None:
                out[s] = hit
        return out


_w_tr = {}
_w_tex = {}


def _worker_init(worker_data):
    global _w_tr, _w_tex
    for loc, (ja_cache, jp_prefab, zhtw_cache, tw_prefab, pid_map, tex_dir) in worker_data.items():
        _w_tr[loc] = TwPrefabTranslator(ja_cache, jp_prefab, zhtw_cache, tw_prefab, pid_map)
        _w_tex[loc] = texture_files(tex_dir)


def _patch_one_tw_bundle(stock_path, crc, loc):
    src = open(stock_path, "rb").read()
    if unityfs.crc(src) != crc:
        return {"error": f"stock CRC {unityfs.crc(src):08x} != catalog {crc:08x}"}
    if target_platform(src) != ANDROID_TARGET:
        return {"error": "not an Android bundle"}
    env = UnityPy.load(src)

    found, trees = [], []
    for obj in env.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        try:
            tree = obj.read_typetree()
        except Exception:
            continue
        cjk = [t for t in texts(tree) if CJK.search(t)]
        if cjk:
            found += cjk
            trees.append((obj, tree))

    mapping = _w_tr[loc].build(found) if found else {}
    fields = 0
    for obj, tree in trees:
        n = replace(tree, mapping)
        if n:
            obj.save_typetree(tree)
            fields += n
    untranslated = sorted(set(found) - set(mapping))

    res = {
        "src_md5": md5(src),
        "text_fields": fields,
        "untranslated": untranslated,
        "textures": [],
        "text": None,
        "images": None,
    }
    if fields:
        res["text"] = forge_crc(env.file.save(packer="original"), crc)
        env = UnityPy.load(res["text"])
    tex = set_textures(env, _w_tex[loc])
    if tex:
        res["textures"] = sorted(set(tex))
        res["images"] = forge_crc(env.file.save(packer="original"), crc)
    for k in ("text", "images"):
        if res[k] is not None:
            assert unityfs.crc(res[k]) == crc
            UnityPy.load(res[k])
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tw-root", default=DEFAULT_TW_ROOT)
    ap.add_argument("--tw-apk", default=DEFAULT_TW_APK)
    ap.add_argument("--jp-stock-dir", default=DEFAULT_JP_STOCK)
    ap.add_argument("--jp-prefabs-zip", default=DEFAULT_JP_PREFABS_ZIP)
    ap.add_argument("--jp-images-zip", default=DEFAULT_JP_IMAGES_ZIP)
    ap.add_argument("--locale", nargs="+", default=["en", "fr"])
    ap.add_argument("--out", default=os.path.join(REPO, "build", "tw"))
    ap.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    ap.add_argument("--skip-ui", action="store_true", help="only build language bundles + caches")
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    tw_meta = os.path.join(a.tw_root, "files", "il2cpp", "Metadata", "global-metadata.dat")
    tw_shared = os.path.join(a.tw_root, "files", "UnityCache", "Shared")
    tw_cat_path = find_tw_catalog(a.tw_root)
    tw_catalog = json.load(open(tw_cat_path, encoding="utf-8"))
    tw_cat = catalog_bundles(tw_catalog)
    tw_checked = crc_checked(tw_catalog)

    lang_entry = tw_cat[TW_LANG_GUID]
    tw_lang_path = os.path.join(tw_shared, TW_LANG_GUID, lang_entry["hash"], "__data")
    tw_lang_bytes = open(tw_lang_path, "rb").read()
    tw_stock_md5 = md5(tw_lang_bytes)
    tw_stock_crc = unityfs.crc(tw_lang_bytes)
    print(
        f"TW stock language bundle: {len(tw_lang_bytes):,} B, md5={tw_stock_md5}, "
        f"crc={tw_stock_crc:08x}, catalog={len(tw_cat)} bundles",
        flush=True,
    )

    key, iv, key_off, iv_off = mtcrypto.find_keys(tw_meta, tw_lang_path)
    print(f"TW metadata offsets: key={key_off:#x}, iv={iv_off:#x}", flush=True)

    _, tw_assets = mtcrypto.text_assets(tw_lang_bytes)
    tw_tables = {n: mtcrypto.decrypt(s, key, iv) for n, (s, _) in tw_assets.items() if n.startswith("e_")}
    print(f"TW tables decrypted: {len(tw_tables)}", flush=True)

    en_ja_cache, _, _, _, _, _ = load_locale_maps("en")
    ja_tables = extract_tw_inapp_ja(a.tw_apk, key, iv, tw_tables, en_ja_cache)
    print(f"TW inapp JA mirror tables extracted: {len(ja_tables)}", flush=True)

    summary = {
        "region": "tw",
        "package": "com.cayenne.mtr",
        "lang_guid": TW_LANG_GUID,
        "lang_hash": lang_entry["hash"],
        "stock_size": len(tw_lang_bytes),
        "stock_md5": tw_stock_md5,
        "stock_crc": f"{tw_stock_crc:08x}",
        "meta_key_off": hex(key_off),
        "meta_iv_off": hex(iv_off),
        "locales": {},
    }

    locale_state = {}
    for loc in a.locale:
        print(f"\n=== Building TW language bundle [{loc}] ===", flush=True)
        ja_cache, jp_hand, tw_extra, jp_prefab, tw_prefab, tex_dir = load_locale_maps(loc)
        out_tables, tw_cache, tw_hand, stats, leftover = translate_tw_tables(
            tw_tables, ja_tables, ja_cache, jp_hand, tw_extra
        )
        print(
            f"  [{loc}] translated cells: ja_cache={stats['ja_cache']}, hand={stats['hand']}, "
            f"tw_extra={stats['tw_extra']}, leftover_cjk={len(leftover)}",
            flush=True,
        )
        if leftover:
            raise SystemExit(f"[{loc}] unexpected untranslated CJK cells ({len(leftover)}): {leftover[:5]}")

        # Try exact-size first; if plaintext/ciphertext exceeds TW stock size (FR), use grown + forged CRC
        exact_ok = (loc == "en")
        try:
            data, newlines, mode = build_tw_language_bundle(tw_lang_bytes, key, iv, out_tables, exact_size=exact_ok)
        except SystemExit:
            data, newlines, mode = build_tw_language_bundle(tw_lang_bytes, key, iv, out_tables, exact_size=False)

        patch_name = "__data.tw" if loc == "en" else f"__data.tw.{loc}"
        patch_path = os.path.join(a.out, patch_name)
        open(patch_path, "wb").write(data)
        print(
            f"  [{loc}] wrote {patch_name}: {len(data):,} B ({mode}, pad_nl={newlines}), "
            f"md5={md5(data)}, crc={unityfs.crc(data):08x}",
            flush=True,
        )

        cache_name = f"translation_cache.tw.{loc}.json"
        cache_path = os.path.join(a.out, cache_name)
        cache_payload = {"cache": tw_cache, "hand": tw_hand}
        cache_bytes = json.dumps(cache_payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        open(cache_path, "wb").write(cache_bytes)
        print(
            f"  [{loc}] wrote {cache_name}: {len(cache_bytes):,} B, md5={md5(cache_bytes)} "
            f"(cache={len(tw_cache)}, hand_tables={len(tw_hand)}, hand_rows={sum(len(v) for v in tw_hand.values())})",
            flush=True,
        )

        locale_state[loc] = (ja_cache, jp_prefab, tw_cache, tw_prefab, tex_dir)
        summary["locales"][loc] = {
            "patch": patch_name,
            "patch_size": len(data),
            "patch_md5": md5(data),
            "patch_crc": f"{unityfs.crc(data):08x}",
            "patch_mode": mode,
            "padding_newlines": newlines,
            "tables_verified": len(out_tables),
            "leftover_cjk_cells": len(leftover),
            "cache": cache_name,
            "cache_size": len(cache_bytes),
            "cache_md5": md5(cache_bytes),
            "cache_entries": len(tw_cache),
            "hand_rows": sum(len(v) for v in tw_hand.values()),
        }

    if not a.skip_ui:
        print("\n=== Mapping JP <-> TW UI Prefab & Image Bundles ===", flush=True)
        jp_cat = catalog_bundles(json.load(open(os.path.join(a.jp_stock_dir, "catalog_ja.json"), encoding="utf-8")))
        tw_by_logical = {logical_name(v["file"]): (guid, v) for guid, v in tw_cat.items()}

        jp_guids = set()
        for zp in (a.jp_prefabs_zip, a.jp_images_zip):
            if os.path.exists(zp):
                for entry in json.loads(zipfile.ZipFile(zp).read("manifest.json")):
                    jp_guids.add(entry["bundle"])

        matched = []  # (tw_guid, tw_entry, jp_file_or_None)
        missing_in_tw = []
        for jp_guid in sorted(jp_guids):
            if jp_guid not in jp_cat:
                continue
            lname = logical_name(jp_cat[jp_guid]["file"])
            if lname not in tw_by_logical:
                missing_in_tw.append(lname)
                continue
            tw_guid, tw_entry = tw_by_logical[lname]
            tw_path = os.path.join(tw_shared, tw_guid, tw_entry["hash"], "__data")
            if not os.path.exists(tw_path):
                raise SystemExit(f"TW bundle not in cache pull: {lname} ({tw_path})")
            jp_path = os.path.join(a.jp_stock_dir, jp_cat[jp_guid]["file"])
            matched.append((tw_guid, tw_entry, tw_path, jp_path if os.path.exists(jp_path) else None))

        # Deduplicate in case two JP GUIDs map to same TW GUID
        seen_tw = set()
        uniq_matched = []
        for item in matched:
            if item[0] not in seen_tw:
                seen_tw.add(item[0])
                uniq_matched.append(item)
        matched = uniq_matched

        crc_checked_matched = sorted(tw_checked & {m[0] for m in matched})
        print(
            f"Matched {len(matched)} TW UI/image bundles ({len(missing_in_tw)} JP-only skipped, "
            f"{len(crc_checked_matched)} CRC-checked when cached)",
            flush=True,
        )

        # Build JP <-> TW path_id alignment dictionary across all matched pairs
        raw_pairs = collections.defaultdict(collections.Counter)
        with ProcessPoolExecutor(a.workers) as ex:
            futs = [ex.submit(collect_path_id_pairs, jp_p, tw_p) for _, _, tw_p, jp_p in matched if jp_p]
            for fu in as_completed(futs):
                for tw_s, jp_s in fu.result():
                    raw_pairs[tw_s][jp_s] += 1
        print(f"JP <-> TW path_id aligned strings: {len(raw_pairs)}", flush=True)

        worker_data = {}
        for loc in a.locale:
            ja_cache, jp_prefab, tw_cache, tw_prefab, tex_dir = locale_state[loc]
            pid_map = {}
            for tw_s, jp_counter in raw_pairs.items():
                for jp_s, _ in jp_counter.most_common():
                    hit = _from_cache(ja_cache, jp_s)
                    if hit is None and jp_s in jp_prefab:
                        hit = jp_prefab[jp_s]
                    if hit is not None:
                        pid_map[tw_s] = hit
                        break
            worker_data[loc] = (ja_cache, jp_prefab, tw_cache, tw_prefab, pid_map, tex_dir)

        out = {
            loc: {"text": ([], {}), "images": ([], {}), "untranslated": set(), "fields": 0}
            for loc in a.locale
        }
        errors = []
        with ProcessPoolExecutor(a.workers, initializer=_worker_init, initargs=(worker_data,)) as ex:
            futs = {
                ex.submit(_patch_one_tw_bundle, tw_path, tw_entry["crc"], loc): (tw_guid, tw_entry, loc)
                for tw_guid, tw_entry, tw_path, _ in matched
                for loc in a.locale
            }
            for fu in as_completed(futs):
                (tw_guid, tw_entry, loc), r = futs[fu], fu.result()
                if "error" in r:
                    errors.append(f"{tw_entry['file']}: {r['error']}")
                    continue
                o = out[loc]
                o["untranslated"].update(r["untranslated"])
                o["fields"] += r["text_fields"]
                for kind in ("text", "images"):
                    data = r[kind]
                    if data is None:
                        continue
                    entries, blobs = o[kind]
                    entries.append({
                        "bundle": tw_guid,
                        "src_md5": r["src_md5"],
                        "out_md5": md5(data),
                        "size": len(data),
                        "text_fields": r["text_fields"],
                        "textures": r["textures"] if kind == "images" else [],
                    })
                    blobs[tw_guid] = data

        if errors:
            raise SystemExit("TW UI bundle errors:\n  " + "\n  ".join(sorted(errors)[:10]))

        for loc in a.locale:
            o = out[loc]
            print(
                f"\n=== Packaging TW UI zips [{loc}] ({o['fields']} fields, "
                f"{len(o['untranslated'])} untranslated) ===",
                flush=True,
            )
            if o["untranslated"]:
                print(f"  [{loc}] untranslated prefab strings: {sorted(o['untranslated'])[:20]}", flush=True)
            for kind, prefix in (("text", "android-prefabs-tw"), ("images", "android-images-tw")):
                entries, blobs = o[kind]
                entries.sort(key=lambda e: e["bundle"])
                zname = f"{prefix}-{loc}.zip"
                zpath = os.path.join(a.out, zname)
                write_zip(zpath, entries, blobs)
                zbytes = open(zpath, "rb").read()
                key_name = "prefabs" if kind == "text" else "images"
                summary["locales"][loc][key_name] = zname
                summary["locales"][loc][f"{key_name}_md5"] = md5(zbytes)
                summary["locales"][loc][f"{key_name}_size"] = len(zbytes)
                summary["locales"][loc][f"{key_name}_bundles"] = len(entries)
                if kind == "images":
                    summary["locales"][loc]["textures_count"] = len({t for e in entries for t in e["textures"]})
            summary["locales"][loc]["prefabs_text_fields"] = o["fields"]
            summary["locales"][loc]["prefabs_untranslated"] = sorted(o["untranslated"])

    sum_path = os.path.join(a.out, "tw-build-summary.json")
    with open(sum_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    print(f"\nWrote {sum_path}", flush=True)


if __name__ == "__main__":
    main()

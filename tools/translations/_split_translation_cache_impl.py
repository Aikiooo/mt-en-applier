#!/usr/bin/env python3
"""Split a built translation_cache.json into themed, one-entry-per-line source files.

For the DEFAULT locale the split is full and lossless: re-merging the output
reproduces the same cache.

For a non-default locale it is SPARSE: pass --canonical (the built default-locale
cache) and only entries whose value differs from it are written, so regenerating
does not re-inflate the default language back into the locale's files.

Keys are sorted everywhere, so output is deterministic.
"""
import json, io, sys, os, argparse, collections

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")


def theme_of(k: str) -> str:
    if any(t in k for t in ("ガチャ", "チケット", "課金石", "スタミナ", "有償", "無償", "ショップ", "交換所")):
        return "gacha-shop"
    if any(t in k for t in ("バトル", "戦闘", "攻撃", "スキル", "ターン", "ダメージ", "防御", "必殺", "クリティカル")):
        return "battle"
    if any(t in k for t in ("クエスト", "章", "話", "エピソード", "ストーリー", "シナリオ")):
        return "story-quest"
    if any(t in k for t in ("設定", "ヘルプ", "タイトル", "ログイン", "アカウント", "データ", "更新", "ダウンロード", "エラー", "通信", "お知らせ")):
        return "ui-system"
    if any(t in k for t in ("キャラ", "装備", "強化", "覚醒", "限界", "進化", "レベル", "ランク", "編成", "パーティ", "Lv")):
        return "character-equip"
    if any(t in k for t in ("ミッション", "実績", "報酬", "プレゼント", "ログボ", "デイリー", "ウィークリー")):
        return "missions-rewards"
    return "dialogue"  # generic scene/story text with no keyword signature


def write_map(path: str, mapping: dict) -> int:
    """Write a JSON object with one entry per line, keys sorted, UTF-8, real JP."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("{\n")
        items = sorted(mapping.items(), key=lambda kv: kv[0])
        for i, (k, v) in enumerate(items):
            line = json.dumps(k, ensure_ascii=False) + ": " + json.dumps(v, ensure_ascii=False)
            f.write("  " + line + (",\n" if i < len(items) - 1 else "\n"))
        f.write("}\n")
    return len(items)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", required=True)
    ap.add_argument("--out", required=True, help="translations root")
    ap.add_argument("--locale", required=True)
    ap.add_argument("--canonical",
                    help="built default-locale cache; when given, emit only entries "
                         "that differ from it (sparse mode)")
    a = ap.parse_args()

    d = json.load(io.open(a.cache, encoding="utf-8"))
    cache, hand = d["cache"], d.get("hand", {})

    if a.canonical:
        canon = json.load(io.open(a.canonical, encoding="utf-8"))
        ccanon, hcanon = canon.get("cache", {}), canon.get("hand", {})

        unknown = [k for k in cache if k not in ccanon]
        if unknown:
            print("ERROR: %d key(s) in the '%s' cache are not in the canonical cache, e.g. %r"
                  % (len(unknown), a.locale, unknown[:5]))
            return 1

        cache = {k: v for k, v in cache.items() if ccanon[k] != v}
        sparse_hand = {}
        for tbl, rows in hand.items():
            kept = {i: v for i, v in rows.items() if hcanon.get(tbl, {}).get(i) != v}
            if kept:
                sparse_hand[tbl] = kept
        hand = sparse_hand
        print("sparse split for '%s': %d differing cache entries" % (a.locale, len(cache)))

    locale_root = os.path.join(a.out, a.locale)

    buckets = collections.defaultdict(dict)
    for k, v in cache.items():
        buckets[theme_of(k)][k] = v

    total = 0
    print("  %s/source/:" % a.locale)
    for theme in sorted(buckets):
        n = write_map(os.path.join(locale_root, "source", theme + ".json"), buckets[theme])
        total += n
        print("    %-18s %6d entries" % (theme, n))

    print("  %s/hand/:" % a.locale)
    for tbl in sorted(hand):
        n = write_map(os.path.join(locale_root, "hand", tbl + ".json"), hand[tbl])
        print("    %-18s %6d entries" % (tbl, n))

    print("total cache entries written: %d (of %d in the cache)" % (total, len(cache)))
    assert total == len(cache), "lost entries in split!"


if __name__ == "__main__":
    sys.exit(main())

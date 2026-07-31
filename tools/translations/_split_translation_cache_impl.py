#!/usr/bin/env python3
"""Split translation_cache.json into themed, one-entry-per-line source files.

Lossless: Build-TranslationCache.ps1 re-merges the output into a byte-identical
cache. Keys are sorted everywhere so output is deterministic.
"""
import json, io, sys, os, argparse, collections, re

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
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    d = json.load(io.open(a.cache, encoding="utf-8"))
    cache, hand = d["cache"], d.get("hand", {})

    buckets = collections.defaultdict(dict)
    for k, v in cache.items():
        buckets[theme_of(k)][k] = v

    total = 0
    print("source/:")
    for theme in sorted(buckets):
        n = write_map(os.path.join(a.out, "source", theme + ".json"), buckets[theme])
        total += n
        print(f"  {theme:18} {n:6} entries")

    print("hand/:")
    for tbl, entries in sorted(hand.items()):
        n = write_map(os.path.join(a.out, "hand", tbl + ".json"), entries)
        print(f"  {tbl:18} {n:6} entries")
    print(f"total cache entries written: {total} (expected {len(cache)})")
    assert total == len(cache), "lost entries in split!"

if __name__ == "__main__":
    main()

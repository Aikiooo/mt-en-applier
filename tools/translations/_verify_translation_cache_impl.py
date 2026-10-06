#!/usr/bin/env python3
"""Semantic-equality check between a rebuilt translation_cache.json and a baseline.

Byte-matching is the wrong target: the original release cache is INSERTION-ordered
(not sorted), while the rebuilt cache is ordinal-sorted. Key order inside a JSON
object is semantically meaningless to the dict consumers that read this file, so
the guarantee CI actually needs is:

  - same set of JP keys in `cache`, each mapping to the same EN value
  - same set of hand tables in `hand`, each with the same keys and values

Exit 0 when semantically identical, 1 otherwise (with a diagnostic diff summary).
"""
import argparse
import io
import json
import sys

# Diff output contains Japanese; the Windows default (cp1252) cannot encode it, so a
# mismatch would crash here instead of printing the diagnostic. Match the splitter.
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def compare_maps(name, a, b, sample=5):
    """Compare two {k: v} dicts. Return a list of problem strings (empty == equal)."""
    problems = []
    ak, bk = set(a.keys()), set(b.keys())
    only_a = ak - bk
    only_b = bk - ak
    if only_a:
        problems.append(
            "%s: %d key(s) only in rebuilt, e.g. %s"
            % (name, len(only_a), sorted(only_a)[:sample])
        )
    if only_b:
        problems.append(
            "%s: %d key(s) only in baseline, e.g. %s"
            % (name, len(only_b), sorted(only_b)[:sample])
        )
    value_diffs = [k for k in (ak & bk) if a[k] != b[k]]
    if value_diffs:
        examples = [
            "%r: rebuilt=%r baseline=%r" % (k, a[k], b[k]) for k in sorted(value_diffs)[:sample]
        ]
        problems.append(
            "%s: %d key(s) with different values, e.g. %s"
            % (name, len(value_diffs), examples)
        )
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rebuilt", required=True)
    ap.add_argument("--baseline", required=True)
    args = ap.parse_args()

    try:
        rebuilt = load(args.rebuilt)
    except Exception as e:
        print("ERROR: cannot parse rebuilt cache %s: %s" % (args.rebuilt, e))
        return 1
    try:
        baseline = load(args.baseline)
    except Exception as e:
        print("ERROR: cannot parse baseline cache %s: %s" % (args.baseline, e))
        return 1

    problems = []
    problems += compare_maps("cache", rebuilt.get("cache", {}), baseline.get("cache", {}))

    r_hand = rebuilt.get("hand", {})
    b_hand = baseline.get("hand", {})
    r_tables, b_tables = set(r_hand.keys()), set(b_hand.keys())
    if r_tables != b_tables:
        problems.append(
            "hand: table sets differ: only in rebuilt=%s only in baseline=%s"
            % (sorted(r_tables - b_tables), sorted(b_tables - r_tables))
        )
    for table in sorted(r_tables & b_tables):
        problems += compare_maps("hand[%s]" % table, r_hand[table], b_hand[table])

    if problems:
        print("MISMATCH: rebuilt cache is NOT semantically identical to the baseline:")
        for p in problems:
            print("  - " + p)
        return 1

    print(
        "OK: rebuilt cache is semantically identical to the baseline "
        "(cache=%d entries, hand-tables=%d)."
        % (len(rebuilt.get("cache", {})), len(r_hand))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

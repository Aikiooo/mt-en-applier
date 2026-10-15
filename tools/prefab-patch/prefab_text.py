"""Japanese text baked into prefabs (TextMeshPro / uGUI `m_text`) and its English.

Screens built before the language bundle is loaded show these serialized
strings, and some labels are never overwritten at runtime. The English comes
from, in order:
  1. translation_cache.json (exact match, then with line breaks normalised),
  2. translations/en/prefab/ui-prefab.json (strings the cache has no line for),
  3. for dev placeholders (あいうえお…, 一二三…), a neutral Latin filler that
     keeps the rich-text tags and line breaks.
"""
import json
import re

CJK = re.compile(r"[぀-ヿ㐀-鿿]")
CJK_RUN = re.compile(r"[　-ヿ㐀-鿿！-｠]+")
FIELDS = ("m_text", "m_Text")
LOREM = "Sample text " * 40


def texts(node):
    """Yield every m_text string in a typetree."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k in FIELDS and isinstance(v, str):
                yield v
            else:
                yield from texts(v)
    elif isinstance(node, list):
        for v in node:
            yield from texts(v)


def replace(node, mapping):
    """Replace mapped m_text strings in place; returns the count."""
    n = 0
    if isinstance(node, dict):
        for k, v in node.items():
            if k in FIELDS and isinstance(v, str) and v in mapping:
                node[k] = mapping[v]
                n += 1
            else:
                n += replace(v, mapping)
    elif isinstance(node, list):
        for v in node:
            n += replace(v, mapping)
    return n


def _from_cache(cache, jp):
    s = jp.strip()
    en = cache.get(s)
    if en is None:
        for v in (s.replace("\r\n", "\n"), s.replace("\r\n", "<br>"), s.replace("\n", "<br>")):
            if v not in cache:
                continue
            en = cache[v]
            # The cache writes line breaks as <br>; prefab text uses real ones.
            # Only convert when the Japanese string has no real <br> of its own,
            # i.e. when the match came from the <br> spelling of the key.
            if "<br>" in v and "<br>" not in s:
                en = en.replace("<br>", "\n")
            break
    if en is None:
        return None
    # keep the original leading/trailing whitespace: layouts rely on it
    return jp[:len(jp) - len(jp.lstrip())] + en + jp[len(jp.rstrip()):]


PLACEHOLDER = re.compile(r"あいう|ああああ|アイウエオ|一二三四五|ダミー")


def filler(jp):
    return CJK_RUN.sub(lambda m: LOREM[:max(4, int(len(m.group()) * 1.6))].rstrip(), jp)


class Translator:
    def __init__(self, cache_path, prefab_map_path):
        self.cache = json.load(open(cache_path, encoding="utf-8"))["cache"]
        self.prefab = json.load(open(prefab_map_path, encoding="utf-8"))
        self.stats = {"cache": 0, "prefab": 0, "placeholder": 0, "untranslated": 0}
        self.untranslated = []

    def build(self, japanese):
        """Map Japanese strings to English. Strings with no translation that are not
        dev placeholders stay Japanese and are listed in self.untranslated."""
        out = {}
        for jp in sorted(set(japanese)):
            en = _from_cache(self.cache, jp)
            if en is not None:
                self.stats["cache"] += 1
            elif jp in self.prefab:
                en = self.prefab[jp]
                self.stats["prefab"] += 1
            elif PLACEHOLDER.search(jp):
                en = filler(jp)
                self.stats["placeholder"] += 1
            else:
                self.stats["untranslated"] += 1
                self.untranslated.append(jp)
                continue
            out[jp] = en
        return out

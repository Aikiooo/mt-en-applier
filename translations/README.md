# Translation sources

This folder is the **human-editable source** of the patch. If you want to fix a
translation, reword a line, or translate the game into another language, this is the
place to do it.

You do **not** need to touch the giant one-line `translation_cache.json` the patch
downloads — that file is *generated* from these sources automatically. Editing these
per-line files means every change shows up as a clean, reviewable diff in a pull request.

## Layout

`locales.json` lists the languages and names the default. Each locale gets its own
folder:

```
<locale>/source/*.json    the JP -> <language> map, one file per theme
<locale>/hand/*.json      the small ID-keyed tables
```

English (`en`) is the **canonical** set of keys. Every other locale is **sparse**: it
only carries the lines it translates, and anything missing falls back to English in
the built patch. That means a new language can land one theme at a time — see
[`es/README.md`](es/README.md) for a worked example.

## The files (English)

`en/source/` is split by theme. Each file is a flat JSON map of
`"Japanese": "English"`, one entry per line, keys sorted:

```json
{
  "18時以降にログインする": "Log in after 18:00",
  "1日1回チャレンジ可能": "Can be challenged once a day"
}
```

| File | Entries | What's in it |
|------|--------:|--------------|
| `en/source/dialogue.json` | 18,819 | Story and spoken dialogue (the big one, kept alphabetical) |
| `en/source/story-quest.json` | 1,400 | Quest / chapter / episode labels |
| `en/source/character-equip.json` | 560 | Characters, equipment, leveling, awakening, party |
| `en/source/battle.json` | 460 | Combat, skills, turns, damage |
| `en/source/ui-system.json` | 344 | Settings, login, account, download, errors, notices |
| `en/source/gacha-shop.json` | 227 | Gacha, shop, currency, exchange, stamina |
| `en/source/missions-rewards.json` | 199 | Missions, achievements, rewards, login bonuses |

`en/hand/` holds the small ID-keyed tables (`e_ui_text`, `e_day_of_week`). Most
contributors won't need these.

## Suggest a fix (no tools needed)

1. Open the file for the theme (check the table above).
2. Find the line and edit the value on the **right** side. Don't touch the Japanese
   key on the left — that's how the game matches text.
3. Send a pull request. GitHub will show exactly the lines you changed.

**Don't know Git?** Open an [issue](https://github.com/Aikiooo/mt-en-applier/issues)
and paste the Japanese line plus your suggestion. A maintainer will make the edit for you.

## A few rules

- **Edit values, not keys.** Changing a Japanese key breaks the match and the line
  falls back to Japanese.
- **Keep one entry per line.** That's what keeps diffs readable.
- **Watch the punctuation.** Quotes inside a value must be escaped (`\"`). If your
  change breaks the JSON, CI will flag it on your PR.
- **One Japanese line = one entry.** The same key can't live in two files (CI checks
  for duplicates).
- **New line you're not sure where it goes?** Put it in the closest theme; a maintainer
  can move it. Theme is cosmetic — all files merge into one cache.

## Translating into another language

Add a folder for the locale (and list it in `locales.json`), then mirror the English
files under `source/` and `hand/`, keeping the Japanese keys/ids and putting your
language on the right. Partial files are fine. [`es/README.md`](es/README.md) has the
details.

## For maintainers

Rebuild one locale from these sources:

```powershell
# default locale (English) -> %TEMP%\translation_cache.json
powershell -File tools\translations\Build-TranslationCache.ps1

# a specific locale -> %TEMP%\translation_cache.<locale>.json
powershell -File tools\translations\Build-TranslationCache.ps1 -Locale es
```

The build prints the coverage for a sparse locale (`N / M entries differ from 'en'`)
and fails if a locale invents a key English doesn't have.

Validate against the currently released cache (semantic equality — same keys and
values; order may differ):

```powershell
powershell -File tools\translations\Build-TranslationCache.ps1 -Locale en -Baseline path\to\translation_cache.json
```

Regenerate the source files from a fresh cache (e.g. after a game update adds new
lines). For a sparse locale, pass the built English cache as `-Canonical` so only the
lines that differ are written back:

```powershell
powershell -File tools\translations\split_translation_cache.ps1 -Cache path\to\translation_cache.json
powershell -File tools\translations\split_translation_cache.ps1 -Cache tc.es.json -Locale es -Canonical tc.en.json
```

Release artifact names: the default locale keeps `translation_cache.json`; others are
`translation_cache.<locale>.json`. The live download stays at
[`patch-latest`](https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/translation_cache.json).

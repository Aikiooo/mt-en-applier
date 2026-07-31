# Translation sources

This folder is the **human-editable source** of the English patch. If you want to fix a translation, reword a line, or translate the game into another language, this is the place to do it.

You do **not** need to touch the giant one-line `translation_cache.json` the patch downloads — that file is *generated* from these sources automatically. Editing these per-line files means every change shows up as a clean, reviewable diff in a pull request.

## The files

The cache is split by theme into `source/`. Each file is a flat JSON map of `"Japanese": "English"`, one entry per line, keys sorted:

```json
{
  "18時以降にログインする": "Log in after 18:00",
  "1日1回チャレンジ可能": "Can be challenged once a day"
}
```

| File | Entries | What's in it |
|------|--------:|--------------|
| `source/dialogue.json` | 18,819 | Story and spoken dialogue (the big one, kept alphabetical) |
| `source/story-quest.json` | 1,400 | Quest / chapter / episode labels |
| `source/character-equip.json` | 560 | Characters, equipment, leveling, awakening, party |
| `source/battle.json` | 460 | Combat, skills, turns, damage |
| `source/ui-system.json` | 344 | Settings, login, account, download, errors, notices |
| `source/gacha-shop.json` | 227 | Gacha, shop, currency, exchange, stamina |
| `source/missions-rewards.json` | 199 | Missions, achievements, rewards, login bonuses |

`hand/` holds the small ID-keyed tables (`e_ui_text`, `e_day_of_week`). Most contributors won't need these.

## Suggest a fix (no tools needed)

1. Open the file for the theme (check the table above).
2. Find the line and edit the English on the **right** side. Don't touch the Japanese key on the left — that's how the game matches text.
3. Send a pull request. GitHub will show exactly the lines you changed.

**Don't know Git?** Open an [issue](https://github.com/Aikiooo/mt-en-applier/issues) and paste the Japanese line plus your suggested English. A maintainer will make the edit for you.

## A few rules

- **Edit values, not keys.** Changing a Japanese key breaks the match and the line falls back to Japanese.
- **Keep one entry per line.** That's what keeps diffs readable.
- **Watch the punctuation.** Quotes inside the English must be escaped (`\"`). If your change breaks the JSON, CI will flag it on your PR.
- **One Japanese line = one entry.** The same key can't live in two files (CI checks for duplicates).
- **New line you're not sure where it goes?** Put it in the closest theme; a maintainer can move it. Theme is cosmetic — all files merge into one cache.

## For maintainers

Rebuild the compact cache from these sources:

```powershell
powershell -File tools\translations\Build-TranslationCache.ps1 -Out "$env:TEMP\translation_cache.json"
```

Validate it against the currently released cache (semantic equality — same keys and values; order may differ):

```powershell
powershell -File tools\translations\Build-TranslationCache.ps1 -Out "$env:TEMP\translation_cache.json" -Baseline path\to\translation_cache.json
```

Regenerate the source files from a fresh cache (e.g. after a game update adds new lines):

```powershell
powershell -File tools\translations\split_translation_cache.ps1 -Cache path\to\translation_cache.json
```

The live download the patch consumes stays at [`patch-latest` / `translation_cache.json`](https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/translation_cache.json). These sources are what you edit; that file is what's shipped.

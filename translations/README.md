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

`en/prefab/` and `en/textures/` are PC-only: text and images baked into the game's
UI bundles, used by [`tools/prefab-patch`](../tools/prefab-patch/README.md), not by
the translation cache. `en/textures/<name>.png` is the English version of the game
texture with that name. A locale published on PC carries its own
`prefab/ui-prefab.json` and `textures/` the same way ([`fr/`](fr/README.md) does);
they are built from that locale's cache and shipped as its `prefab_patch` and
`prefab_images`.

English (`en`) is the **canonical** set of keys. Every other locale is **sparse**: it
only carries the lines it translates, and anything missing falls back to English in
the built patch. That means a new language can land one theme at a time — see
[`es/README.md`](es/README.md) for a worked example. A locale that has translated
everything simply carries every key — [`fr/`](fr/README.md) does.

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

To have the locale published on PC as well — its own UI text, images and title
screen, not just its translated text — give it `prefab/ui-prefab.json` and
`textures/`, laid out like [`fr/prefab/ui-prefab.json`](fr/prefab/ui-prefab.json)
and [`fr/textures/`](fr/textures/) do. The maintainer section below builds and
publishes them.

## Translating images

Images with Japanese lettering (buttons, banners, gacha and event logos, badges,
tutorial captions) are redrawn per language in `translations/<code>/textures/`:

- One PNG per game texture, named exactly after it (`Icon_Home_Command_Gacha.png`).
  [`en/textures/`](en/textures/) lists every texture covered today; start from the
  English file, or from the Japanese original extracted from the game.
- Keep the game's size. A PNG of another size is stretched to it, without keeping
  the aspect ratio.
- Keep the transparency and the art: only the lettering changes. The English set
  removes the Japanese text, rebuilds the background, then letters the new text in
  the game's fonts and styles (gradient fill, outline, glow).
- A missing PNG leaves that texture Japanese for the locale. A PNG named after a
  texture the game doesn't have is reported by the build and ignored.

The same folder feeds both platforms:

- **PC:** `build_prefab_patch.py --textures translations/<code>/textures` (DXT).
- **Android:** `build_android_prefabs.py --locale <code>` (ASTC 6×6, from the Android
  CDN stock, with the menu text of `prefab/ui-prefab.json` and the language's cache),
  published with `publish_android_images.py --kind prefabs images`. The app offers
  menus and images for a language once their keys are on the release; menus install
  unless the player turns them off, images only when the player turns on
  **Translated images**.

Details: [`tools/prefab-patch/README.md`](../tools/prefab-patch/README.md#textures).

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

### Publishing a language to the app

The Android app lists a language only once the release's `version.json` names it
under a `locales` block. `Publish-Locale.ps1` builds the cache, merges that block
(every other key is left alone) and, with `-Publish`, uploads the assets first and
`version.json` last:

```powershell
# Auto-patch only: ships translation_cache.es.json; the phone builds the bundle
powershell -File tools\translations\Publish-Locale.ps1 -Locale es -Publish

# also offer Download: attach a ready-made __data.es built for the current game build
powershell -File tools\translations\Publish-Locale.ps1 -Locale es -PatchFile path\to\__data_es -Stock path\to\android_stock -Publish

# also offer it on PC: an exact-size, CRC-forged bundle for the current PC build
powershell -File tools\translations\Publish-Locale.ps1 -Locale es -PcPatchFile path\to\language-ja_es.bundle -Publish

# the whole PC patch, like English: language bundle, UI prefabs + images, title screen
powershell -File tools\translations\Publish-Locale.ps1 -Locale fr -BuildPcPatch `
    -PcPrefabDir build\prefab-patch-fr -PcInappBuild build\inapp_assets_all_fr.bundle -Publish

# withdraw a language from the app
powershell -File tools\translations\Publish-Locale.ps1 -Locale es -Unpublish -Publish
```

- It refuses a locale with nothing translated yet (`-Force` overrides).
- `-BuildPatch -Stock … -KeysJson …` builds `__data.<locale>` with the app's own
  AutoPatcher. That bundle is **grown, not exact-size**; test it on a phone before
  publishing.
- PC: the installer offers a language only when its bundle targets the current PC
  game build (same asset hash as English), and the bundle must be exactly the
  English bundle's size (the PC catalog pins it).
- PC assets: build `-PcPrefabDir` with `tools/prefab-patch/build_prefab_patch.py`
  (`--translation-cache` this locale's cache, `--prefab-map
  translations/<code>/prefab/ui-prefab.json`, `--textures translations/<code>/textures`)
  and `-PcInappBuild` with `tools/prefab-patch/build_inapp.py`, both from a **stock**
  cache and game (`Install-PrefabPatch.ps1 -Restore` first): a bundle built from an
  already patched file is refused on every player's machine. They go under
  `locales.<code>.pc` as `prefab_patch`, `prefab_images` and `inapp`, and the
  installer installs them exactly as it does English's. `label` (from
  `locales.json`) names the launcher: `Play-in-French.cmd`.
- The installer scripts themselves (`tools/pc/*.ps1`, `MT.EnPatch.psm1`) must be on
  the release too: older copies ignore everything but the language bundle.
- After a game update, a language's ready-made patch no longer fits the game: the
  app's **Install** notices it (it compares the tables' row ids) and builds the
  translation on the phone instead.
- After a game update the maintainer's automation adds the update's new lines to
  `en/` as released, translates them into each published language, commits them
  here and re-runs `Publish-Locale.ps1`, so French follows each update. A new line
  that fails its checks stays in English until someone fixes it by hand.
- The older `update_translation.py` rewrites `version.json` from scratch, which drops
  the `locales` block, the `images` keys and `cache_md5`; `update_pipeline.py` keeps
  them. After a release made with the older script, re-run `Publish-Locale.ps1` and
  `publish_android_images.py` for each language and put back `cache_md5` (see the
  main README's Releasing section).

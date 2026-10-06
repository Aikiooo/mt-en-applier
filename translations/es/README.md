# Spanish translation (`es`)

This directory holds the Spanish translation. It is **sparse**: you only add the
entries whose Spanish differs from the English in [`../en/source/`](../en/source/).
Everything you leave out falls back to English in the built patch, so this can land
in pieces — one theme at a time is fine.

## How to translate

1. Pick a theme in `../en/source/` (see [`../README.md`](../README.md) for what each
   one holds).
2. Create `source/<theme>.json` here with the **same Japanese keys** as the English
   file, and the Spanish on the right:

   ```json
   {
     "18時以降にログインする": "Inicia sesión después de las 18:00"
   }
   ```

3. Do **not** rename, reorder, or invent keys. English is the canonical key set; a key
   that does not exist in `../en/` fails the build.
4. `hand/` tables work the same way, but they are keyed by row id (not by Japanese),
   so mirror the ids from `../en/hand/`.

You do not have to translate a whole file in one go — a partial file is valid.

## Rules

- **Edit values, not keys.** The Japanese key is how the game matches the line.
- **Keep one entry per line.** That is what makes pull requests reviewable.
- **Escape quotes** inside the Spanish (`\"`); CI rejects malformed JSON.
- A key may live in only one file here.

## Checking your work

```powershell
# build the Spanish cache (English fills the gaps) and print coverage
powershell -File tools\translations\Build-TranslationCache.ps1 -Locale es
```

The build prints `N / M entries differ from 'en'`. A key with the exact same value as
English is treated as untranslated.

> Note: Spanish runs ~15–25% longer than English. The patch re-encrypts each table at
> a fixed byte length, so very long lines fall back to Japanese on their own. Translate
> naturally; do not shorten a line just to match the English length.

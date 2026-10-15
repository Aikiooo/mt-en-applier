# PC prefab + in-app patch ("load twice" fix)

Two English builds that sit next to the language bundle on PC (DMM). Together
they make the **first** load fully English, so players no longer need to go back
to the title screen.

| Build | Where it goes | What it fixes |
|-------|---------------|---------------|
| `build_prefab_patch.py` → 243 cached bundles (`ui_*`, `menu_*`, …) | Unity cache, like the language bundle | ~7,270 Japanese strings baked into prefabs (TextMeshPro `m_text`). Screens built before the language bundle loads showed them, and ~400 static labels were never overwritten at all (Apple/Google sign-in, data-transfer notes, purchase warnings, the Displacement Incident text…). |
| `build_inapp.py` → `inapp_assets_all_en.bundle` | `StreamingAssets`, only while the game runs (`tools/pc/Watch-InappSwap.ps1`) | The title screen of the first load: it runs from the in-app bundle, which carries its own Japanese/dev copy of the 140 `e_*` tables plus 150 baked strings. |

Both were tested in-game on client 1.2.0 (2026-10-15). The title screen and its
menu are English on the first launch, and DMM still starts the game normally.

## Why the existing `inapp_assets_all_en.bundle` showed a black screen

The game loads the in-app bundle **with the stock CRC**, although the local catalog
declares none. The `Player.log` from a run with the current release file shows it:

```
CRC Mismatch. Provided 792f43a1, calculated fb179f42 from data. Will not load AssetBundle 'aa\StandaloneWindows64\inapp_assets_all.bundle'
```

Unity's CRC is a CRC32 of the *decompressed* block stream; `unityfs.py` reproduces
it (`fb179f42` for the released file). `build_inapp.py` sets 4 bytes of alignment
padding between two serialized objects, which Unity never reads, so the CRC equals
the stock one. Size doesn't matter for this bundle.

## Translations

- First source: the released `translation_cache.json` (721 of the 1,152 distinct strings).
- Then `translations/en/prefab/ui-prefab.json`: 376 strings the cache has no line for.
  It sits outside `source/`, so `Build-TranslationCache.ps1`, CI and the released
  cache are unchanged. It uses the existing glossary (Bond, Raid, Magic Stone,
  Recollections, Data Transfer…).
- Dev placeholders (`あいうえお…`, `一二三…`) become `Sample text`; the game overwrites
  them at runtime.
- Anything else stays Japanese and is listed in `untranslated.json`: add it to
  `ui-prefab.json` and rebuild.

## Build (maintainer, after each game update)

```powershell
py -m pip install -r tools\prefab-patch\requirements.txt
# The cache must be stock (Japanese) for the prefab scan: run Install-PrefabPatch.ps1 -Restore first.
py -I -X utf8 tools\prefab-patch\build_prefab_patch.py --translation-cache translation_cache.json
py -I -X utf8 tools\prefab-patch\build_inapp.py --language-bundle language-ja_en.bundle --translation-cache translation_cache.json
```

- Outputs go to `build\prefab-patch\` (plus `manifest.json`, `untranslated.json` and `crc-checked.json`) and `build\inapp_assets_all_en.bundle` (plus `.json`).
- `build_inapp.py` finds the AES key in `global-metadata.dat` on its own. The PC offsets
  for 1.2.0 are `0xba5ab8` (key) and `0xba8538` (IV), not Android's `0xbc3df0`/`0xbc6870`.
- Builds are deterministic: the same inputs give byte-identical files.
- `crc-checked.json` lists the cached bundles the current catalog verifies with
  `m_UseCrcForCachedBundles`, which are therefore left stock (none of them carries UI
  text today). If that file grows, the game moved UI text into a verified bundle.

## Install (player)

Wired into the normal installer. Either flag works on its own; `-WithAssets` is both:

```powershell
Install-EnPatch.ps1 -WithAssets     # or -Prefabs / -FirstLoad
# one-line, no download of the zip:
& ([scriptblock]::Create((irm https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/install.ps1))) -WithAssets
# back to Japanese (undoes both halves):
Install-EnPatch.ps1 -Restore
```

- `-Prefabs` downloads `prefab-patch.zip` (~40 MB: the bundles are already compressed),
  unpacks it to `%LOCALAPPDATA%\MT-EN-Applier\pc\prefab-patch` and installs it with
  `tools\pc\Install-PrefabPatch.ps1` (md5-gated per bundle, originals backed up).
- `-FirstLoad` downloads the in-app bundle, writes the metadata
  `Watch-InappSwap.ps1` verifies against, and starts that watcher in its own window. It
  also writes `%LOCALAPPDATA%\MT-EN-Applier\pc\Play-in-English.cmd`, which is what the
  player starts the game with from then on: DMM verifies the in-app bundle before it
  starts the game, so the English file can only be in place while the game runs.

## Publishing (maintainer)

```powershell
powershell -File tools\pc\maintainer\Publish-PcPatch.ps1            # stage, review
powershell -File tools\pc\maintainer\Publish-PcPatch.ps1 -Publish   # upload to patch-latest
```

It refuses to publish the prefab zip unless every `src_md5` in `manifest.json` still
matches the local cache (i.e. the build was made from the stock cache the players have),
and it uploads `version.json` last so no installer sees a version.json that points at
files which aren't uploaded yet.

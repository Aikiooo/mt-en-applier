# PC prefab + in-app patch ("load twice" fix)

Two English builds that sit next to the language bundle on PC (DMM). Together
they make the **first** load fully English, so players no longer need to go back
to the title screen.

| Build | Where it goes | What it fixes |
|-------|---------------|---------------|
| `build_prefab_patch.py` → 353 cached bundles (`ui_*`, `menu_*`, …) | Unity cache, like the language bundle | ~7,270 Japanese strings baked into prefabs (TextMeshPro `m_text`). Screens built before the language bundle loads showed them, and ~400 static labels were never overwritten at all (Apple/Google sign-in, data-transfer notes, purchase warnings, the Displacement Incident text…). Plus 137 textures with Japanese lettering, redrawn in English (see [Textures](#textures)). |
| `build_inapp.py` → `inapp_assets_all_en.bundle` | `StreamingAssets`, only while the game runs (`tools/pc/Watch-InappSwap.ps1`) | The title screen of the first load: it runs from the in-app bundle, which carries its own Japanese/dev copy of the 140 `e_*` tables plus 150 baked strings, and the Japanese title logo. |

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

## Textures

`translations/en/textures/<name>.png` holds the English version of each game
texture (`Texture2D`) that has Japanese lettering. 138 are covered today: gacha and event
logos, banners, home-screen buttons, badges and adventurer titles, stamps,
enhancement-quest cards, subscription art, and the captions of the *Lose tips* /
*How to play* screenshots. Each was rebuilt from the original: the Japanese
lettering was removed and the background reconstructed (LaMa inpainting), then the
English was lettered on top in the game's own fonts and styles (gradient fill,
outlines, glow), so it matches the art direction. The 32 *How to play*
screenshots whose only Japanese is small UI text inside the screenshot are left
as they are.

- `textures.py` re-encodes every `Texture2D` with that name, keeping its format
  (DXT1/DXT5/RGBA32), size and mip count (`Texture2D.set_image`; the DXT encoder is
  `etcpak`, a UnityPy dependency). The data size stays the same, and every other
  object in the bundle is untouched.
- `build_prefab_patch.py` writes them in the same pass as the text: 137 textures in
  113 cached bundles, 3 of which also carry prefab text and get one file with both.
  Each manifest entry lists its `textures`. The installer and `Publish-PcPatch.ps1`
  are unchanged: a texture bundle is md5-gated and backed up like any other.
- `build_inapp.py` writes `TitleLogo_01`, which only exists in the in-app bundle,
  before the CRC is forged back.
- None of the textures sits in a CRC-checked bundle.
- To fix or add one, replace or drop a PNG named after the texture, at the game's
  size, and rebuild. Pass `--textures ""` to either script for a text-only build.

Tested in-game on client 1.2.0 (2026-10-16), with the same builds byte for byte.

## Android images

The Android client caches the same image bundles, under the same name folder
(`UnityCache/Shared/<name folder>/`); only the version folder differs. 137 of the
textures above are there (all but `TitleLogo_01`), as **ASTC 6×6 without mips**, and `textures.set_textures`
re-encodes them in that format (UnityPy with `astc_encoder`). The game doesn't
CRC-check these bundles on Android: the patched files load as they are.

`build_android_images.py` builds one zip per language from **stock** Android bundles:

```powershell
# stock bundles, one file per name folder (pull them from a phone that never had images installed)
adb shell 'cd /sdcard/Android/data/jp.gree_ent.mushoku/files/UnityCache/Shared; for d in <name folders>; do cp "$(ls -t $d/*/__data | head -1)" /data/local/tmp/ab/$d; done'
adb pull /data/local/tmp/ab ..\mt_db\build\android_image_stock

py -I -X utf8 tools\prefab-patch\build_android_images.py --stock ..\mt_db\build\android_image_stock --locale fr
py -I -X utf8 tools\prefab-patch\publish_android_images.py --locale fr            # dry run
py -I -X utf8 tools\prefab-patch\publish_android_images.py --locale fr --publish
```

- The name folders are the first part of each `rel` in `build/prefab-patch/manifest.json`.
- Output: `build/android-images-<locale>.zip`, about 17 MB: `manifest.json`
  (`bundle`, `src_md5`, `out_md5`, `size`, `textures`) and one patched bundle per name
  folder. Builds are deterministic.
- `TitleLogo_01` is reported as missing: on Android it lives in the in-app bundle,
  inside the game's APK.
- The publisher uploads the zip, then merges `images`, `images_md5` and `images_size`
  into `version.json` (top level for English, `locales.<code>` otherwise).
- The app writes a cached bundle only when its md5 is the manifest's `src_md5` or one
  it wrote itself. After a game update changes a bundle, that bundle stays Japanese
  until the zip is rebuilt from the new stock.

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

Wired into the normal installer. The text side installs without asking; the
redrawn images get one question (default yes, 60 s of silence means yes):

```powershell
Install-EnPatch.ps1                # text + images, asks about the images
Install-EnPatch.ps1 -WithAssets    # no question: images too
Install-EnPatch.ps1 -NoImages      # no question: text only
Install-EnPatch.ps1 -LanguageOnly  # no question: language bundle only
Install-EnPatch.ps1 -Prefabs       # one half on its own
# one-line, no download of the zip:
& ([scriptblock]::Create((irm https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/install.ps1)))
# back to Japanese (undoes both halves):
Install-EnPatch.ps1 -Restore
```

`Install-PrefabPatch.ps1` takes `-SkipTextures` to install the text/prefab side
and leave the image-only bundles stock (that is what answering no to the question
does), and `-Check` / `-Restore` as before.

- `-Prefabs` downloads `prefab-patch.zip` (~39.5 MB: the bundles are already compressed),
  unpacks it to `%LOCALAPPDATA%\MT-EN-Applier\pc\prefab-patch` and installs it with
  `tools\pc\Install-PrefabPatch.ps1` (md5-gated per bundle, originals backed up).
- `-FirstLoad` downloads the in-app bundle, writes the metadata
  `Watch-InappSwap.ps1` verifies against, and starts that watcher in its own window. It
  also writes `%LOCALAPPDATA%\MT-EN-Applier\pc\Play-in-English.cmd`, which is what the
  player starts the game with from then on: DMM verifies the in-app bundle before it
  starts the game, so the English file can only be in place while the game runs.
- Other languages publish their own builds of both (see
  [`translations/README.md`](../../translations/README.md#publishing-a-language-to-the-app)):
  build them with that language's cache, `--prefab-map translations/<code>/prefab/ui-prefab.json`
  and `--textures translations/<code>/textures`, from the same stock cache.

## Publishing (maintainer)

```powershell
powershell -File tools\pc\maintainer\Publish-PcPatch.ps1            # stage, review
powershell -File tools\pc\maintainer\Publish-PcPatch.ps1 -Publish   # upload to patch-latest
```

It refuses to publish the prefab zip unless every `src_md5` in `manifest.json` still
matches the local cache (i.e. the build was made from the stock cache the players have),
and it uploads `version.json` last so no installer sees a version.json that points at
files which aren't uploaded yet.

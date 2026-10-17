# MT-EN Applier

Unofficial **English patch** for *Mushoku Tensei: Chronicle of Echoes*, on Android
and Windows (DMM).

<p align="center"><strong>New here?</strong> The plain-language walkthrough covers every platform with pictures:</p>

<p align="center">
  <a href="https://mtcoe.com/#/en-patch"><img src="https://img.shields.io/badge/%F0%9F%93%96%20Open%20the%20walkthrough-e0b44c?style=flat" alt="📖 Open the walkthrough" width="235"></a>
</p>

> **Last patch:** 2026-10-09 (v13). See [patch-latest](https://github.com/Aikiooo/mt-en-applier/releases/tag/patch-latest) for the current build.

## Get the patch

| Platform | How | Guide |
|----------|-----|-------|
| **Android phone** (no root) | The MT-EN Applier app + Shizuku | [below](#android-phone) |
| **Windows PC** (DMM GAME PLAYER) | One PowerShell command, or a zip | [below](#windows-pc-dmm) · [`tools/pc/README.md`](tools/pc/README.md) |
| **Android emulator / rooted / Google Play Games PC** | adb script | [`tools/reapply-en-patch.ps1`](tools/reapply-en-patch.ps1) |

Every platform installs the same translation, from the rolling
[`patch-latest`](https://github.com/Aikiooo/mt-en-applier/releases/tag/patch-latest) release.

> **Load twice for full translation.** Some screens fetch their text on first load
> and cache it, so a few lines can stay Japanese the very first time. Go back to the
> title menu and re-enter; the second load is fully English. This applies to every
> platform. On **PC** it can be removed entirely with the optional `-WithAssets` step
> in the Windows section below.

### Android phone

You need Android 11 or newer and [Shizuku](https://play.google.com/store/apps/details?id=moe.shizuku.privileged.api)
(free; it lets the app write into the game's folder without root).

1. **Start Shizuku** via wireless debugging (it stays on until you reboot).
2. **Open the game once** to the title screen so it downloads its data, then close it.
3. **Install `MT-EN-Applier.apk`** from the [latest release](https://github.com/Aikiooo/mt-en-applier/releases/latest)
   and allow the Shizuku permission when asked.
4. Tap **Install English**, then launch the game.

`INSTALL.md` on the release page walks through each step, including Shizuku's pairing.

- **Updating from v2.2.2 or older:** uninstall the app once, then install the new
  APK. v2.4.0 moved to a permanent signing key, so Android can't install it over
  the old one. Your game and patch aren't affected, and later versions install
  over the top. The app now shows a **Get update** banner when a new version is out.
- **After a game update:** open the app and tap **Install** again. If no patch for
  the new game version is out yet, Install builds the translation on the phone in a
  few seconds instead (Auto-patch; only brand-new text stays Japanese). The **?**
  next to Install explains this in the app.
- **Translated images** (opt-in): turn on the **Translated images** switch and the
  next Install also replaces the buttons, banners and logos that have Japanese
  lettering, in the chosen language (about 17 MB).
- **Advanced:** **Rebuild on this phone (Auto-patch)** forces the on-phone build, and
  **Install a __data file…** installs a patch file you picked.
- **Back to Japanese:** **Delete all language packs (reset)** for the text and
  **Remove translated images** for the images; the game re-downloads the Japanese
  files at next launch.
- **Shizuku keeps stopping?** See the troubleshooting section of `INSTALL.md`, and
  tap the status card at the top of the app for **Diagnostics**.

### Windows PC (DMM)

Launch the game once to the title screen, close it, then open **PowerShell** and paste:

```powershell
irm https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/install.ps1 | iex
```

Then click **Play** in DMM GAME PLAYER. Re-run the same command after a game update.

- **Fully English on the first load (default, PC only).** The text the game itself
  ships — the cached UI prefabs and the in-app bundle behind the first-load title
  screen — installs without asking; that's what the patch has always done, just
  more of it. The **redrawn images** (logos, banners, buttons, badges, tutorial
  captions) are the one thing it asks about, because they change the art:
  yes is the default, and so is 60 seconds of silence. They arrive inside the same
  a separate 23.2 MB download, fetched only if they say yes, so answering no saves it.
  `-WithAssets` answers yes up front, `-NoImages` and `-LanguageOnly` say no.
  Because the in-app half can't stay installed (DMM verifies that file before
  launching), a small watcher swaps it in per session: start the game with
  `Play-in-English.cmd` (`Play-in-French.cmd`, ... in another language), then click Play.
  Every published language ships all of it, not only its text.
  **[`tools/pc/README.md`](tools/pc/README.md)** has the details.
- **No terminal?** Download the zip from the [PC English Patch release](https://github.com/Aikiooo/mt-en-applier/releases/tag/pc-v1),
  extract it and double-click `Install-EnPatch.bat`. `START-HERE.txt` inside is the
  whole guide.
- **Back to Japanese:** `Restore-Japanese.bat` in the zip, or the command above with `-Restore`.
- **Link your account first:** the PC client has no in-game account recovery.
  [`tools/pc/README.md`](tools/pc/README.md) explains, along with every option
  (`-Check`, `-Language`, `-GameDir`).

## Languages

English is the only published language today. A **French** translation is complete
and ready to publish (PC, everything English has: `Publish-Locale.ps1 -Locale fr -BuildPcPatch
-PcPrefabDir … -PcInappBuild …`); a
**Spanish** one is in progress. The translation lives in [`translations/`](translations/) as readable,
one-line-per-entry files, so anyone can suggest a fix or translate into another
language with a normal pull request. [`translations/README.md`](translations/README.md)
explains how.

Once a second language is published, the Android app shows a **Patch language**
picker and the PC installer asks which language to install. Until then, both behave
exactly as they do now.

---

## For developers and maintainers

### What the app does

`MainActivity` reaches a shell (ADB uid) through Shizuku: a bound `UserService`, or a
one-shot `Shizuku.newProcess` fallback for phones whose task killer blocks the
service. It force-stops the game, finds every live language bundle (`__data`) under
`/sdcard/Android/data/jp.gree_ent.mushoku/files/…/UnityCache/Shared/` (the asset-hash
folder changes with updates, and a mirror lives under `files/il2cpp/`), copies the
patch over each, and checks the size on the device.

- **Install** reads `version.json` on `patch-latest`, downloads the selected language's
  patch and verifies its size and md5, checks it against the game (below) and copies
  it. With no patch published for the language, or none that fits, it runs Auto-patch.
- **Auto-patch** takes the AES keys from the game's own `global-metadata.dat`
  (offsets from `version.json`), decrypts the new bundle, overlays the translation
  cache and rebuilds it on the phone (`core/AutoPatcher`). The status card shows its
  progress. Details below.
- **Translated images** (opt-in) overwrite the game's cached image bundles with the
  release's per-language build. Details below.

**The shell can overwrite the game's cache files but not delete them.** The cache
folders are `drwxr-s---` (owner: the game, group `ext_data_rw`) and the files
`rw-rw----`, so the shell uid (in `ext_data_rw`) can write a file but not unlink it.
To make the game download a bundle again, the app empties that entry's `__info`
(Unity's cache record, `-1 / timestamp / 1 / __data`): Unity then treats the entry
as not cached and downloads it at next launch. Reset, Remove translated images and
Auto-patch's re-download all work this way.

**Auto-patch always translates from Japanese.** The translation cache matches
Japanese text, so patching an already patched bundle changes almost nothing. Before
patching, it counts the Japanese text cells of the source (`AutoPatcher.Result
.sourceIsJapanese()`: the stock bundle is ~99% Japanese, a patched one ~0%):

1. It keeps a copy of the Japanese bundle whenever it sees one (`original_ja.__data`
   in the app's files, also taken by Install before it overwrites the stock bundle).
2. When the game holds a patch this app installed, it starts from that copy, if the
   copy is the bundle that patch was built from.
3. Otherwise it empties the language entries' `__info`, opens the game, waits for
   Unity to write the fresh Japanese bundle (its `__info` comes back), closes the
   game and patches that. If the game doesn't download it within two minutes, it
   asks the player to open the game once and retry.

**Install falls back to Auto-patch after a game update.** Before copying, Install
decrypts the patch and the game's live language pack and compares the row ids of
every table (`AutoPatcher.rowIds`, about a second on a phone). Row ids are the same
in every language, so they differ only when the game data changed: then the game
has updated since the patch was published, and Install runs Auto-patch instead of
installing a patch that lacks the new rows. File sizes can't tell this: a patch
doesn't have to keep the stock size.

When a translated table is too long for its ciphertext, rows go back to Japanese,
longest first. The patcher sizes that by arithmetic (the plaintext length is the sum
of its rows) and encrypts once, so the whole patch takes about half a second on a PC.

**Translated images.** The game caches its image bundles like the language pack, at
`UnityCache/Shared/<name folder>/<version folder>/__data`. The name folder is the same
as on PC; only the version folder differs. Android textures are ASTC 6×6.
`android-images-<code>.zip` on the release holds each patched bundle under its name
folder plus a manifest with its stock (`src_md5`) and patched (`out_md5`) md5. The
app overwrites a cached copy only when it is stock or a bundle it wrote itself (any
language), so switching languages works and a bundle the game updated stays
Japanese. Switching to a language without images, or with the switch off, takes
away the previous language's images rather than mixing them. Built by
[`tools/prefab-patch/build_android_images.py`](tools/prefab-patch/build_android_images.py);
see [`tools/prefab-patch/README.md`](tools/prefab-patch/README.md#android-images).
- **Update check** looks for the highest `vX.Y.Z` GitHub release carrying `MT-EN-Applier.apk`.

The APK contains no game data and no encryption keys.

### Build

```bat
gradlew.bat assembleDebug     :: app\build\outputs\apk\debug\app-debug.apk
gradlew.bat assembleRelease   :: app\build\outputs\apk\release\app-release.apk (signed)
```

AGP 9.3.0 / Gradle 9.5.1, Java 17 bytecode, `compileSdk 37`, `minSdk 26`. The UI is
plain Java with no UI libraries. Dependencies: the vendored Shizuku API client
(`rikka.shizuku.*`, `moe.shizuku.*` AIDL; MIT, © RikkaApps), `hiddenapibypass` for
hidden-API access on Android 9+, and `lz4-java` plus `org.tukaani:xz` (LZMA blocks)
for the auto-patcher.

Release builds are signed with the project key, which lives **outside the repo**
(`~/.android/mt-en-applier-release.properties`, or `-PmtReleaseProps=<path>`).
Without it, release builds are unsigned. Every published APK must use that same key,
or users can't update over their installed copy.

### Releasing

- **App:** tag `vX.Y.Z` and attach the release build as **`MT-EN-Applier.apk`** (plus
  `INSTALL.md`). The in-app update check depends on both the tag format and the file name.
  Don't do it by hand: bump `versionName`/`versionCode` in `app/build.gradle`, commit and push
  `main`, then run [`tools/Release-App.ps1`](tools/Release-App.ps1) (stages and verifies; add
  `-Notes <file> -Publish` to release). It refuses a dirty/unpushed tree, an existing tag, a
  version mismatch, or any signing key other than the project's. `INSTALL.md` is versioned at
  [`docs/INSTALL.md`](docs/INSTALL.md); the script fills in the size/MD5 in the attached copy.
- **Patch:** the English patch (`__data`, `version.json`, `translation_cache.json`, PC
  bundles) is published to `patch-latest` by the maintainer pipeline;
  [`tools/pc/maintainer/Publish-PcPatch.ps1`](tools/pc/maintainer/Publish-PcPatch.ps1)
  adds the PC block — the language bundle, the in-app bundle with the stock metadata
  the swap watcher needs, and `prefab-patch.zip` (it verifies that build against the
  local game cache before uploading).
- **PC installer:** [`tools/pc/maintainer/Build-PcZip.ps1`](tools/pc/maintainer/Build-PcZip.ps1) `-Publish`
  uploads the zip and the one-line installer together, so both always run the same scripts.
- **Other languages:** [`tools/translations/Publish-Locale.ps1`](tools/translations/Publish-Locale.ps1)
  (see [`translations/README.md`](translations/README.md#publishing-a-language-to-the-app)).
  Re-run it after each English release, which rewrites `version.json`.
- **Android images:** [`tools/prefab-patch/publish_android_images.py`](tools/prefab-patch/publish_android_images.py)
  `--locale <code> --publish` (English included). Re-run it after each English release too.
- **English cache:** `version.json` must carry a top-level `cache_md5` (the md5 of
  `translation_cache.json`). The app re-downloads its cache only when that stamp
  changes, so a cache uploaded without it never reaches the phones that have one.

### Roadmap

- Ready-made Spanish bundles for Android and PC (exact-size builds, like the English one).
- Keep the `locales` block of `version.json` when the English release is republished.
- Server-side auto-build on game updates (GitHub Actions / watcher), so `patch-latest`
  refreshes without a manual run.
- Textures for events newer than the redrawn set (e.g. the current pickup banners), and
  the title logo on Android, which lives inside the game's APK.
- Android first-load fix: the in-app bundle there lives inside the APK, so the PC
  approach (swap the StreamingAssets copy at launch) doesn't transfer.

## Legal / disclaimer

Unofficial fan project, not affiliated with GREE, Beaglee or the rights holders. The
patch is a fan-made translation layered onto the game's own data; game text © its
respective owners. Use at your own risk.

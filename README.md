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
> platform.

### Android phone

You need Android 11 or newer and [Shizuku](https://play.google.com/store/apps/details?id=moe.shizuku.privileged.api)
(free; it lets the app write into the game's folder without root).

1. **Start Shizuku** via wireless debugging (it stays on until you reboot).
2. **Open the game once** to the title screen so it downloads its data, then close it.
3. **Install `MT-EN-Applier.apk`** from the [latest release](https://github.com/Aikiooo/mt-en-applier/releases/latest)
   and allow the Shizuku permission when asked.
4. Tap **Download latest patch**, then **Apply English patch**, then launch the game.

`INSTALL.md` on the release page walks through each step, including Shizuku's pairing.

- **Updating from v2.2.2 or older:** uninstall the app once, then install the new
  APK. v2.4.0 moved to a permanent signing key, so Android can't install it over
  the old one. Your game and patch aren't affected, and later versions install
  over the top. The app now shows a **Get update** banner when a new version is out.
- **After a game update:** open the app, **Download latest patch**, **Apply**. If no
  patch for the new game version is out yet, **Auto-patch after update (beta)**
  rebuilds the translation on the phone (only brand-new text stays Japanese).
- **Back to Japanese:** **Delete all language packs (reset)**; the game re-downloads
  the Japanese text.
- **Shizuku keeps stopping?** See the troubleshooting section of `INSTALL.md`, and
  tap the status card at the top of the app for **Diagnostics**.

### Windows PC (DMM)

Launch the game once to the title screen, close it, then open **PowerShell** and paste:

```powershell
irm https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/install.ps1 | iex
```

Then click **Play** in DMM GAME PLAYER. Re-run the same command after a game update.

- **No terminal?** Download the zip from the [PC English Patch release](https://github.com/Aikiooo/mt-en-applier/releases/tag/pc-v1),
  extract it and double-click `Install-EnPatch.bat`. `START-HERE.txt` inside is the
  whole guide.
- **Back to Japanese:** `Restore-Japanese.bat` in the zip, or the command above with `-Restore`.
- **Link your account first:** the PC client has no in-game account recovery.
  [`tools/pc/README.md`](tools/pc/README.md) explains, along with every option
  (`-Check`, `-Language`, `-GameDir`).

## Languages

English is the only published language today; a **Spanish** translation is in
progress. The translation lives in [`translations/`](translations/) as readable,
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

- **Download** reads `version.json` on `patch-latest` and verifies the patch's size and md5.
- **Auto-patch (beta)** takes the AES keys from the game's own `global-metadata.dat`
  (offsets from `version.json`), decrypts the new bundle, overlays the translation
  cache and rebuilds it on the phone (`core/AutoPatcher`).
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
hidden-API access on Android 9+, and `lz4-java` for the auto-patcher.

Release builds are signed with the project key, which lives **outside the repo**
(`~/.android/mt-en-applier-release.properties`, or `-PmtReleaseProps=<path>`).
Without it, release builds are unsigned. Every published APK must use that same key,
or users can't update over their installed copy.

### Releasing

- **App:** tag `vX.Y.Z` and attach the release build as **`MT-EN-Applier.apk`** (plus
  `INSTALL.md`). The in-app update check depends on both the tag format and the file name.
- **Patch:** the English patch (`__data`, `version.json`, `translation_cache.json`, PC
  bundles) is published to `patch-latest` by the maintainer pipeline;
  [`tools/pc/maintainer/Publish-PcPatch.ps1`](tools/pc/maintainer/Publish-PcPatch.ps1)
  adds the PC block.
- **PC installer:** [`tools/pc/maintainer/Build-PcZip.ps1`](tools/pc/maintainer/Build-PcZip.ps1) `-Publish`
  uploads the zip and the one-line installer together, so both always run the same scripts.
- **Other languages:** [`tools/translations/Publish-Locale.ps1`](tools/translations/Publish-Locale.ps1)
  (see [`translations/README.md`](translations/README.md#publishing-a-language-to-the-app)).
  Re-run it after each English release, which rewrites `version.json`.

### Roadmap

- Ready-made Spanish bundles for Android and PC (exact-size builds, like the English one).
- Keep the `locales` block of `version.json` when the English release is republished.
- Server-side auto-build on game updates (GitHub Actions / watcher), so `patch-latest`
  refreshes without a manual run.

## Legal / disclaimer

Unofficial fan project, not affiliated with GREE, Beaglee or the rights holders. The
patch is a fan-made translation layered onto the game's own data; game text © its
respective owners. Use at your own risk.

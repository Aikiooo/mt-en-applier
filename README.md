# MT-EN Applier

Unofficial **English patch** for *Mushoku Tensei: Chronicle of Echoes*.

<p align="center"><strong>New here?</strong> The plain-language walkthrough covers every platform with pictures:</p>

<p align="center">
  <a href="https://mtcoe.com/#/en-patch"><img src="https://img.shields.io/badge/%F0%9F%93%96%20Open%20the%20walkthrough-e0b44c?style=flat" alt="📖 Open the walkthrough" width="235"></a>
</p>

One translation, every platform. Pick yours:

> **Last patch:** 2026-10-09 (v13). See [patch-latest](https://github.com/Aikiooo/mt-en-applier/releases/tag/patch-latest) for the current build.

| Platform | Method | Guide |
|----------|--------|-------|
| **Android phone** (no root) | Shizuku app | this page (below) |
| **Windows PC (DMM)** | Ready-to-use zip (download, double-click) | [PC English Patch release](https://github.com/Aikiooo/mt-en-applier/releases) · [`tools/pc/README.md`](tools/pc/README.md) |
| **Android emulator / rooted / GPG-PC** | adb script | [`tools/reapply-en-patch.ps1`](tools/reapply-en-patch.ps1) |

PC users: **no repo clone, no terminal**. Grab the zip from the
[Releases](../../releases) tab, extract it, and double-click `Install-EnPatch.bat`
once. Then just click **Play** in DMM GAME PLAYER. `START-HERE.txt` in the zip is
the whole guide in plain language.

All three pull the same translation from the rolling
[`patch-latest`](https://github.com/Aikiooo/mt-en-applier/releases/tag/patch-latest)
release.

---

## Android (Shizuku app)

One-tap installer for the **unofficial English patch** for the mobile game
*Mushoku Tensei: Chronicle of Echoes* (`jp.gree_ent.mushoku`).

No root, no PC, no storage permission — it uses
[Shizuku](https://shizuku.rikka.app/) (`bindUserService`, shell/ADB uid) to copy
the patched language bundle (`__data`) over the game's UnityCache copy.

## Features (v2.0)

- One-tap apply, status light, optional self-uninstall.
- **Download latest patch**: fetches `version.json` + `__data` from the rolling
  `patch-latest` GitHub release, verifies size+md5. Manual SAF picker kept as fallback.
- **Auto-patch after update (beta)**: fully on-device recovery after a game update —
  the app extracts the AES keys from the game's own `global-metadata.dat`, decrypts
  the new language bundle, overlays the downloaded translation cache (only brand-new
  cells stay Japanese), and writes the rebuilt bundle back. No PC, no waiting for a
  new patch build.
- **Update-proof paths:** auto-discovers the live bundle path at apply time. The
  game's asset-hash cache subfolder changes on some updates, and a mirrored copy
  lives under `files/il2cpp/<m>/UnityCache/Shared` — the app globs both roots and
  patches every live copy found (falls back to the known v1.0.5 path with a warning).

## Requirements

- Android 11+ (minSdk 26; tested on Android 13–16).
- [Shizuku](https://play.google.com/store/apps/details?id=moe.shizuku.privileged.api)
  running (start via wireless debugging; survives until reboot).

## Install

1. Download **`MT-EN-Applier.apk`** and **`__data`** from the
   [Releases](../../releases) page (`INSTALL.md` there is the full guide).
2. Install the game, open it once to the title screen so it downloads its
   data, then fully close it.
3. Install the APK, open it, grant the Shizuku permission when prompted.
4. Tap **Choose __data file…** → pick the downloaded `__data` →
   **Apply English patch** → launch the game.
5. After a game update, just re-open the app and apply again (v1.1 finds the
   new file location by itself).

> **Load the game twice for full translation.** Some screens fetch their text on
> first load and cache it, so a few parts can stay Japanese on the very first
> run. If that happens, **go back to the title menu and re-enter** — the second
> load renders fully in English. (The same applies to the PC method.)

## Build from source

```bat
gradlew.bat assembleDebug
:: output: app\build\outputs\apk\debug\app-debug.apk
```

Android Studio project — AGP 9.3.0 / Gradle 9.5.1, Java 17, `compileSdk 37`.
The Shizuku API client (`rikka.shizuku.*`, `moe.shizuku.*` AIDL) is vendored
(MIT, © RikkaApps) and `org.lsposed.hiddenapibypass` is used for hidden-API
access on Android 9+.

## How it works

`MainActivity` binds a Shizuku `UserService` (`UserService.exec`), force-stops
the game, resolves the live `__data` path(s) under
`/sdcard/Android/data/jp.gree_ent.mushoku/files/…/UnityCache/Shared/`,
`cp`s the staged patch over each copy, `chmod 0666`, and verifies the
on-device size. The APK itself contains no game data and no encryption keys.

## Legal / disclaimer

Unofficial fan project — not affiliated with GREE, Beaglee, or the rights
holders. The companion `__data` patch (Releases) is a fan-made English
translation layered onto the game's own data; game text © its respective
owners. Use at your own risk.

## Roadmap

- "New patch available" indicator on the status line.
- Signed release builds (currently debug-signed).
- Server-side auto-build on game updates (GitHub Actions / watcher) so the
  `patch-latest` tag is refreshed without human intervention.

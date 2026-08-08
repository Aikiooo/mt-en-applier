# PC English Patch (DMM GAME PLAYER client)

Unofficial English patch for the **Windows / DMM** release of *Mushoku Tensei: Chronicle of Echoes* (`mushoku_coe_cl`). This is the PC counterpart to the Android app in the repo root — both share the same translation from the rolling [`patch-latest`](https://github.com/Aikiooo/mt-en-applier/releases/tag/patch-latest) release.

> Fan project, not affiliated with GREE / Beaglee / the rights holders. Game text © its owners. Use at your own risk. Online games can change their integrity checks at any time; if a game update breaks this, re-run the installer.

> **⚠️ Link your account before you play — this is not optional.** The PC client signs you in through DMM and has **no in-game account recovery**. That's a property of the game, not of this patch — the patch never touches your save or your account. But if you reinstall, move PCs, or anything goes wrong on an **unlinked** account, there is no way to get it back. Binding is only possible from the **Android** version: log into the same account there and link it to a Google account in the game settings. Failing that, only use this patch on an account you've just started. (If you've been playing patched with no issues, that's expected — this is cheap insurance, the same "bind your account" advice as any gacha game.)

## TL;DR — just make it English

**You don't need this repo or any command lines.** Grab the ready-to-use zip:

1. **Download** the zip from the [PC English Patch release](https://github.com/Aikiooo/mt-en-applier/releases) and extract it anywhere.
2. Double-click **`Install-EnPatch.bat`** — once. It does everything.
3. Double-click **`Play-En.bat`** every time you play, then click **Play** in DMM GAME PLAYER. Leave the window open while you play.

Open **`START-HERE.txt`** in the zip — it's the whole guide in plain language.
(Or read the same guide in your browser: https://www.mtcoe.com/#/en-patch.)

### Rather run it from a terminal / from this repo?

```powershell
# once:
powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1

# every time you play:
powershell -ExecutionPolicy Bypass -File Play-En.ps1
```

If the installer can't find the game, pass its folder: `Install-EnPatch.ps1 -GameDir 'D:\Games\mushoku_coe_cl'`

## What "patched" means here

The PC client checks files in **two different places**, so the patch is two parts:

| Part | Where it lives | What it does |
|------|----------------|--------------|
| **Language bundle** | Unity Addressables **cache** (`…\LocalLow\Unity\GREE Entertainment_クロエコ\…\__data`) | The bulk of the text. An exact-size, CRC-forged English rebuild. |
| **inapp patch** | `…\StreamingAssets\aa\StandaloneWindows64\inapp_assets_all.bundle` | Remaining in-app strings, swapped in only while the game runs. |

Two rules make this work (learned the hard way):

1. **Leave the Addressables catalog pristine.** The game validates every bundle against the catalog's pinned `m_BundleSize` and `m_Crc` (a CRC32 of the *decompressed* stream). Editing the catalog — or feeding a bundle whose size/CRC doesn't match — is exactly what produces the **"Failed to acquire resources"** error. The fix is to rebuild the bundle to the stock byte size and forge the matching CRC, then drop it in the cache.
2. **Never leave the inapp bundle patched on disk.** DMM GAME PLAYER verifies all ~68 game files against the server manifest on every launch and repairs any mismatch. So `Play-En.ps1` keeps the **stock** bundle in place for the check, swaps the EN patch in the instant the game exe spawns (the file check is already done), and restores stock when the game exits.

## Requirements

- Windows 10/11 with PowerShell 5.1+ (the built-in `powershell.exe`).
- The game installed via DMM GAME PLAYER, **launched once to the title screen** so it downloads its data and creates its cache folders.
- Internet access (to fetch the patch from GitHub Releases).

## Install

1. Run the game once to the title screen, then close it.
2. Run `Install-EnPatch.ps1`. It will:
   - download `language-ja_en.bundle` + `inapp_assets_all_en.bundle` from `patch-latest` and verify size + md5,
   - seed the language bundle into the Unity cache `__data`,
   - snapshot clean stock copies (`stock_inapp_assets_all.bundle`, `stock_boot.config`) into `%LOCALAPPDATA%\MT-EN-Applier\pc\` for the wrapper.
3. That's it — patching is done. You don't re-run this unless the game updates.

## Play

Run `Play-En.ps1`, then click **Play** in DMM GAME PLAYER (or let the script try to launch it for you). Leave the PowerShell window open while you play — it restores the stock files when you quit. `-NoLaunch` arms the watcher without auto-launching.

### Tip (same as Android): load twice for full coverage

Some screens only pull their text on the first load. If you see a stray Japanese line, **go back to the title menu and re-enter** — the second load renders fully in English. This matches the Android behaviour (see the root README).

## After a game update

A title-update usually refreshes the inapp bundle and the cached language bundle. Just re-run `Install-EnPatch.ps1` (it re-downloads and re-seeds), then play via `Play-En.ps1` again.

## Uninstall

- Delete the seeded cache folder `…\GREE Entertainment_クロエコ\<guid>\<hash>\` (or just let the game re-download), and
- in DMM GAME PLAYER, use the game's **file verify / repair** to restore the stock inapp bundle, then delete `%LOCALAPPDATA%\MT-EN-Applier\pc\`.

## Troubleshooting

- **"Failed to acquire resources" at join/login** → the language bundle in the cache doesn't match the catalog (wrong size/CRC). Re-run `Install-EnPatch.ps1`; don't hand-edit the catalog.
- **DMM "repairs" the patch away** → you launched without `Play-En.ps1`. Always start via the wrapper so the stock bundle is present for the file check.
- **Some text still Japanese** → see the "load twice" tip above; otherwise the translation may simply not cover that string yet (the same cache drives Android).
- **Installer can't find the game** → pass `-GameDir` with the folder containing `mushoku_coe_cl.exe`.

## Files

| File | Purpose |
|------|---------|
| `Install-EnPatch.bat` | Double-click installer wrapper (runs the `.ps1`). **Start here.** |
| `Install-EnPatch.ps1` | One-command installer: download, verify, seed cache, capture stock. |
| `Play-En.bat` | Double-click play wrapper — run this every time, then click Play in DMM. |
| `Play-En.ps1` | Launch wrapper: stock for the DMM check, EN swap at spawn, restore on exit. |
| `MT.EnPatch.psm1` | Shared constants + functions (cache seeding, download/verify, game detection). |
| `START-HERE.txt` | The 3-step plain-language guide for non-technical users. |
| `maintainer/` | Maintainer-side builders that produce the release artifacts (PC bundles + `version.json`, and this user zip). |

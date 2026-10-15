# PC English Patch (DMM GAME PLAYER client)

Unofficial English patch for the **Windows / DMM** release of *Mushoku Tensei: Chronicle of Echoes* (`mushoku_coe_cl`). This is the PC counterpart to the Android app in the repo root — both share the same translation from the rolling [`patch-latest`](https://github.com/Aikiooo/mt-en-applier/releases/tag/patch-latest) release.

> Fan project, not affiliated with GREE / Beaglee / the rights holders. Game text © its owners. Use at your own risk. Online games can change their integrity checks at any time; if a game update breaks this, re-run the installer.

> **⚠️ Link your account before you play — this is not optional.** The PC client signs you in through DMM and has **no in-game account recovery**. That's a property of the game, not of this patch — the patch never touches your save or your account. But if you reinstall, move PCs, or anything goes wrong on an **unlinked** account, there is no way to get it back. Binding is only possible from the **Android** version: log into the same account there and link it to a Google account in the game settings. Failing that, only use this patch on an account you've just started. (If you've been playing patched with no issues, that's expected — this is cheap insurance, the same "bind your account" advice as any gacha game.)

## TL;DR — just make it English

**Quickest: one command, nothing to download.** Open PowerShell (Start menu → type
*PowerShell*), paste this, press Enter:

```powershell
irm https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/install.ps1 | iex
```

It runs the same installer as the zip below. Then click **Play** in DMM GAME PLAYER.
To check first without changing anything:
`& ([scriptblock]::Create((irm https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/install.ps1))) -Check`
(`-GameDir 'D:\Games\mushoku_coe_cl'` works the same way if the game isn't found.)

**Fully English on the first load (PC only).** Without the extra pieces, a few
screens stay Japanese until you go back to the title menu once. Two of them fix
that — the English text baked into the game's cached UI prefabs, and the English
in-app bundle the first load's title screen reads — and the installer **asks**
before doing it:

```
Also install the full English UI text? (rewrites the text the game ships: the
cached UI prefabs and the first-load screen; ~105 MB)
    [Y] yes (default)   [N] no    ... 60 s
```

Yes is the default, and sixty seconds of silence means yes, so a plain run ends
up fully English either way. Answer it up front instead with `-WithAssets` (no
question) or `-LanguageOnly` (language bundle only); `-Prefabs` and `-FirstLoad`
are the two halves.

It asks because it rewrites files the game ships (~105 MB: 40 MB of prefabs +
61 MB in-app + the language bundle), and because the in-app half cannot stay
installed — DMM verifies that file before it starts the game, so a small watcher
swaps it in as the game starts and puts the stock file back on exit. The
installer starts that watcher for the current session and writes
**`Play-in-English.cmd`** (`%LOCALAPPDATA%\MT-EN-Applier\pc`) — use it for later
sessions, then click Play.

**Or use the ready-to-use zip** (no command line at all):

1. **Download** the zip from the [PC English Patch release](https://github.com/Aikiooo/mt-en-applier/releases) and extract it anywhere.
2. Double-click **`Install-EnPatch.bat`** — once. It asks one question (full English UI text? default yes, 60 s), then does everything.
3. Click **Play** in DMM GAME PLAYER and play in English. The language bundle stays patched in the game's cache until the game updates; if the in-app half was installed, start the game with `Play-in-English.cmd` instead.

Open **`START-HERE.txt`** in the zip — it's the whole guide in plain language.
(Or read the same guide in your browser: https://www.mtcoe.com/#/en-patch.)

### Rather run it from a terminal / from this repo?

```powershell
# once:
powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1
```

If the installer can't find the game, pass its folder: `Install-EnPatch.ps1 -GameDir 'D:\Games\mushoku_coe_cl'`

## What "patched" means here

The PC client checks files in **three different places**, so the patch is three parts:

| Part | Where it lives | What it does |
|------|----------------|--------------|
| **Language bundle** | Unity Addressables **cache** (`…\LocalLow\Unity\GREE Entertainment_クロエコ\…\__data`) | The bulk of the text. An exact-size, CRC-forged English rebuild. |
| **UI prefabs** (`-Prefabs`) | Same Unity cache | ~7,270 strings baked into 243 cached UI bundles, including ~400 labels the game never overwrites (sign-in, data transfer, purchase warnings). |
| **in-app patch** (`-FirstLoad`) | `…\StreamingAssets\aa\StandaloneWindows64\inapp_assets_all.bundle` | The first load's title screen, plus 150 baked in-app strings. Swapped in only while the game runs. |

Three rules make this work (learned the hard way):

1. **Leave the Addressables catalog pristine.** The game validates the bundles it *downloads* against the catalog's pinned `m_BundleSize` and `m_Crc` (a CRC32 of the *decompressed* stream) — editing the catalog, or feeding a bundle whose size/CRC doesn't match, is exactly what produces the **"Failed to acquire resources"** error. That is why the language bundle is rebuilt to the stock byte size with a forged CRC. The UI prefabs are a different case: their catalog entries carry `m_UseCrcForCachedBundles: false`, so the cached copies are not verified, and 243 transformed bundles can be dropped in as-is (the builder skips the 76 entries that *are* verified, and says so in `crc-checked.json`).
2. **The language bundle and the prefabs live in the cache, not in the game files.** The installer seeds them into the Unity Addressables cache (`…\LocalLow\Unity\GREE Entertainment_クロエコ\…\__data`), which DMM's per-launch file verification does not touch — so they stay applied until the game itself refreshes that cache (a title update). If DMM ever repairs or the game updates, just re-run `Install-EnPatch.bat`.
3. **The in-app bundle cannot stay.** DMM verifies `inapp_assets_all.bundle` before it starts the game, so the English build is staged next to the game folder (`<game>\..\mt-en-staging`, same drive) and swapped in for the session by `Watch-InappSwap.ps1`. Run the watcher before each session (`Play-in-English.cmd`).

## Requirements

- Windows 10/11 with PowerShell 5.1+ (the built-in `powershell.exe`).
- The game installed via DMM GAME PLAYER, **launched once to the title screen** so it downloads its data and creates its cache folders.
- Internet access (to fetch the patch from GitHub Releases).

## Install

1. Run the game once to the title screen, then close it.
2. Run `Install-EnPatch.ps1`. It will:
   - download the language bundle (`language-ja_en.bundle`, or the chosen language's) from `patch-latest` and verify size + md5,
   - seed the language bundle into the Unity cache `__data`,
   - snapshot clean stock copies (`stock_inapp_assets_all.bundle`, `stock_boot.config`) into `%LOCALAPPDATA%\MT-EN-Applier\pc\`.
3. That's it — patching is done. You don't re-run this unless the game updates.

Add `-Prefabs`, `-FirstLoad` or `-WithAssets` (both) to also rewrite the text the
game ships itself; see the top of this file. With `-FirstLoad` the installer also
writes `Play-in-English.cmd`, which is what you start the game with afterwards.

It refuses to install when the game's newest language-pack folder isn't the one the
patch targets (the game hasn't been launched since an update, or the patch for a new
game version isn't out yet): seeding that folder would silently do nothing. `-Force`
overrides.

### Other languages

Only languages published for the current game build are offered. With just English
there's no question; with more, the installer shows a short menu (default: your last
choice, else your Windows display language, else English) and remembers the answer,
so re-running after a game update doesn't ask again. Skip the menu with `-Language es`
(or `& ([scriptblock]::Create((irm …/install.ps1))) -Language es`).

## Play

The installer seeds the language bundle into the game's Unity cache — that's the patch. Just click **Play** in DMM GAME PLAYER; no launcher or terminal needed while playing.

### Tip (same as Android): load twice for full coverage

Some screens only pull their text on the first load. If you see a stray Japanese line, **go back to the title menu and re-enter** — the second load renders fully in English. This matches the Android behaviour (see the root README).

That quirk is PC-fixable: `-WithAssets` rewrites both the cached UI prefabs and the in-app bundle the first load reads. See [`tools/prefab-patch/README.md`](../prefab-patch/README.md).

## After a game update

A title-update usually refreshes the game's cached language bundle, wiping the patch. Just re-run `Install-EnPatch.ps1` (it re-downloads and re-seeds), then click Play in DMM again. With `-Prefabs`, re-run it the same way once the prefab build for the new game build is published: it only applies a build whose recorded game build matches, and reports the bundles the update replaced.

## Uninstall (back to Japanese)

- Double-click **`Restore-Japanese.bat`** (or run the installer with `-Restore`). It removes
  the patched language pack, puts the Japanese UI prefabs back and cleans up any in-app
  swap left behind; the game re-downloads the Japanese one on the title screen.
- Optionally delete `%LOCALAPPDATA%\MT-EN-Applier\pc\` — only *after* a successful
  `-Restore`, since it holds the original bundles the prefab restore needs. `-Restore`
  also clears `…\mt-en-staging` next to the game folder.

## Troubleshooting

- **"Failed to acquire resources" at join/login** → the language bundle in the cache doesn't match the catalog (wrong size/CRC). Re-run `Install-EnPatch.ps1`; don't hand-edit the catalog.
- **DMM "repairs" the patch away** → a DMM file repair or a game update restored the stock files. Re-run `Install-EnPatch.bat`.
- **Some text still Japanese** → see the "load twice" tip above; otherwise the translation may simply not cover that string yet (the same cache drives Android).
- **Installer can't find the game** → pass `-GameDir` with the folder containing `mushoku_coe_cl.exe`.

## Files

| File | Purpose |
|------|---------|
| `install.ps1` | One-line web installer (`irm … \| iex`): fetches the scripts below from `patch-latest` and runs them. Not in the zip. |
| `Install-EnPatch.bat` | Double-click installer wrapper (runs the `.ps1`; options work, e.g. `Install-EnPatch.bat -WithAssets`). **Start here.** |
| `Install-EnPatch.ps1` | One-command installer: download, verify, seed cache, capture stock. `-Language`, `-Check` (report only), `-Restore`, `-Prefabs`, `-FirstLoad`, `-WithAssets`. |
| `Install-PrefabPatch.ps1` | Installs/restores the English UI prefabs in the Unity cache (`-Prefabs`). |
| `Watch-InappSwap.ps1` | Per-session in-app swap for the first load (`-FirstLoad`); `-RestoreOnly` repairs a crashed swap. |
| `Restore-Japanese.bat` | Double-click undo: runs the installer with `-Restore`. |
| `MT.EnPatch.psm1` | Shared constants + functions (cache seeding, download/verify, game detection). |
| `START-HERE.txt` | The plain-language guide for non-technical users. |
| `maintainer/` | Maintainer-side builders that produce the release artifacts (PC bundles + `version.json`, and this user zip). |

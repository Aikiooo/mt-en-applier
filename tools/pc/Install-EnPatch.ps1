<#
.SYNOPSIS
  One-command installer for the Mushoku Tensei PC translation patch (DMM client).

.DESCRIPTION
  - Downloads the latest patch for the chosen language from the rolling
    'patch-latest' GitHub release and verifies size + md5.
  - Seeds the exact-size, CRC-forged language bundle into the Unity
    Addressables cache (__data). The catalog is left untouched; editing the
    catalog is what triggers the "Failed to acquire resources" integrity error.
  - Captures clean stock copies (inapp bundle + boot.config) so DMM file
    repairs stay reversible.

  With -Prefabs / -FirstLoad (or both at once: -WithAssets) it also rewrites the
  game's own shipped text, which is why those are opt-in:
  - -Prefabs puts the English UI-prefab bundles into the same Unity cache, next
    to the language bundle (~230 MB download, once per game build). They carry
    the ~7,270 strings baked into UI prefabs, including ~400 labels the game
    never overwrites at runtime.
  - -FirstLoad stages the English in-app bundle and starts the swap watcher, so
    the first load's title screen is English too. DMM verifies that file before
    starting the game, so it can only be in place while the game runs: the
    watcher swaps it in as the game starts and puts the stock file back on exit.
    Run it before each session (or use the generated Play-in-English.cmd).

  Languages: only the ones published for the current game build are offered.
  With one (English) there is no prompt; with several, a short menu appears
  (default: last choice, else the Windows display language, else English) and
  the choice is remembered for the next run. -Language skips the menu.

  Run this once. After that, just click Play in DMM GAME PLAYER (plus the
  watcher per session if -FirstLoad was used).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -WithAssets        # full first-load fix
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -GameDir 'D:\Games\mushoku_coe_cl' -Force
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -Language es
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -Check     # report only, change nothing
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -Restore   # back to Japanese
#>
param(
    [string]$GameDir,
    [switch]$Force,
    # Patch language code (en, es, ...); skips the menu.
    [string]$Language,
    # Report what an install would do (game, cache, current language), change nothing.
    [switch]$Check,
    # Remove everything this installer put in place, so the game re-downloads Japanese.
    [switch]$Restore,
    # Rewrite the English text baked into the cached UI prefabs (persistent).
    [switch]$Prefabs,
    # Stage the English in-app bundle and start its swap watcher (per session).
    [switch]$FirstLoad,
    # -Prefabs + -FirstLoad.
    [switch]$WithAssets,
    # Do not start the watcher (used by -Check; the caller may do it itself).
    [switch]$NoWatcher
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot      # absolute even when invoked as -File tools\pc\...
Import-Module (Join-Path $here 'MT.EnPatch.psm1') -Force

if ($WithAssets) { $Prefabs = $true; $FirstLoad = $true }

$prefabDir = Join-Path $PatchDataDir 'prefab-patch'
$prefabBackupDir = Join-Path $PatchDataDir 'prefab-backup'

# The two helper scripts are fetched on demand: the zip ships them, but the
# one-line web installer only downloads what this run needs. Each one imports
# MT.EnPatch.psm1 from its own folder, so the module is copied alongside.
function Get-AssetScript([string]$Name) {
    foreach ($p in @((Join-Path $here $Name), (Join-Path $PatchDataDir $Name))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    New-Item -ItemType Directory -Force -Path $PatchDataDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $here 'MT.EnPatch.psm1') -Destination $PatchDataDir -Force
    $dst = Join-Path $PatchDataDir $Name
    Write-Host "  fetching $Name ..."
    Get-RemoteFile -Uri "$ReleaseBase/$Name" -Destination $dst
    return $dst
}

# Restore is also the repair path: any of these may be left behind by a crash.
function Invoke-WatcherRepair([string]$KnownGameDir) {
    $watcher = Get-AssetScript 'Watch-InappSwap.ps1'
    # Named parameters, not an array splat: splatted arrays bind positionally.
    if ($KnownGameDir) { & $watcher -RestoreOnly -GameDir $KnownGameDir | Out-Null }
    else { & $watcher -RestoreOnly | Out-Null }
}

function Invoke-PrefabRestore {
    if (-not (Test-Path -LiteralPath $prefabDir)) { return $false }
    $script = Get-AssetScript 'Install-PrefabPatch.ps1'
    & $script -PatchDir $prefabDir -Restore
    return $true
}

Write-Host 'MT-EN PC installer'

# A game that is running holds the cache and StreamingAssets open, and the
# watcher's rules only make sense between sessions.
if (Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue) {
    Write-Host 'Close the game first, then run this again.'
    exit 1
}

# --- restore: no download needed ----------------------------------------------
if ($Restore) {
    $knownGame = $null
    try { $knownGame = Get-GameDir -Override $GameDir } catch { }   # uninstalled: nothing to repair
    if ($knownGame) {
        # Cheap and idempotent: puts a stock in-app bundle back if a session
        # died mid-swap, and drops the staged English copy.
        try { Invoke-WatcherRepair $knownGame }
        catch { Write-Host "NOTE: could not clean the in-app staging folder: $($_.Exception.Message)" }
    }

    if (Invoke-PrefabRestore) { Write-Host 'Restored: the cached UI prefabs are Japanese again.' }

    $cacheDir = Get-LangCacheDir
    $data = if ($cacheDir) { Join-Path $cacheDir '__data' }
    if (-not $data -or -not (Test-Path -LiteralPath $data)) {
        Write-Host 'No patched language pack in the game cache - nothing else to restore.'
        exit 0
    }
    Remove-Item -LiteralPath $data -Force
    $info = Join-Path $cacheDir '__info'
    if (Test-Path -LiteralPath $info) { Remove-Item -LiteralPath $info -Force }
    Write-Host 'Restored: the patched language pack was removed.'
    Write-Host 'Launch the game; it re-downloads the Japanese text on the title screen.'
    exit 0
}

# --- 1. locate the game -----------------------------------------------------
$gameDir = Get-GameDir -Override $GameDir
if (-not $gameDir) {
    Write-Host @"
Could not find the game automatically.
Pass its folder explicitly, e.g.:
  Install-EnPatch.ps1 -GameDir 'D:\Games\mushoku_coe_cl'
(The folder must contain $($GameExeName).)
"@
    exit 1
}
Write-Host "game dir : $gameDir"

$liveInapp = Join-Path $gameDir $InappRelPath
$liveBoot  = Join-Path $gameDir $BootCfgRelPath
foreach ($f in @($liveInapp, $liveBoot)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "ERROR: expected game file missing: $f"; exit 1 }
}

# --- 2. release info + language ----------------------------------------------
if ($Check) {
    # Read-only: version.json is kept in memory, nothing is written. Decoded as
    # UTF-8 explicitly: 5.1 assumes Latin-1 when the server sends no charset
    # (GitHub release assets don't), which would garble non-ASCII language names.
    $raw = (Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBase/$VersionFile").RawContentStream.ToArray()
    $version = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
} else {
    $version = Get-ReleaseInfo
}
$langs = @(Get-PcLanguages -Version $version)
$settingsPath = Join-Path $PatchDataDir 'settings.json'

function Read-SavedLanguage {
    try {
        if (Test-Path -LiteralPath $settingsPath) {
            return (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).language
        }
    } catch { }
    return $null
}

if ($Language) {
    $chosen = $langs | Where-Object { $_.Code -eq $Language } | Select-Object -First 1
    if (-not $chosen) {
        Write-Host "Language '$Language' isn't published for this game version. Available: $(($langs | ForEach-Object { $_.Code }) -join ', ')"
        exit 1
    }
} elseif ($langs.Count -eq 1) {
    $chosen = $langs[0]
} else {
    $saved = Read-SavedLanguage
    $osLang = (Get-UICulture).TwoLetterISOLanguageName
    $default = $langs | Where-Object { $_.Code -eq $saved } | Select-Object -First 1
    $from = 'last time'
    if (-not $default) { $default = $langs | Where-Object { $_.Code -eq $osLang } | Select-Object -First 1; $from = 'Windows language' }
    if (-not $default) { $default = $langs[0]; $from = 'default' }
    $chosen = $default
    $canAsk = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    if ($Check) {
        Write-Host "languages    : $(($langs | ForEach-Object { $_.Name }) -join ', ') (would default to $($default.Name))"
    } elseif ($saved -and $default.Code -eq $saved) {
        Write-Host "language : $($chosen.Name) (from last time; pass -Language <code> to change)"
    } elseif ($canAsk) {
        Write-Host ''
        Write-Host 'Patch language:'
        for ($i = 0; $i -lt $langs.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $langs[$i].Name) }
        $defIdx = [array]::IndexOf(@($langs | ForEach-Object { $_.Code }), $default.Code) + 1
        $ans = Read-Host "Choose [$defIdx]"
        if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $langs.Count) { $chosen = $langs[[int]$ans - 1] }
    } else {
        Write-Host "language : $($chosen.Name) ($from)"
    }
}

# The asset patches are built per game build; both are published under pc.
$prefabPub = Get-Prop (Get-Prop $version 'pc') 'prefab_patch'
$inappPub  = Get-Prop (Get-Prop $version 'pc') 'inapp_assets_all_en'
$gameHash  = Get-Prop (Get-Prop $version 'pc').language_ja_en 'hash'

# --- 3. check mode -------------------------------------------------------------
if ($Check) {
    $want = $chosen.Want
    Write-Host "latest patch : $($chosen.Name), $($want.size) B, md5 $($want.md5.Substring(0,8))..., game build $($version.game_version)"
    $cacheDir = Get-LangCacheDir
    $live = if ($cacheDir) { Join-Path $cacheDir '__data' }
    if (-not $cacheDir) {
        Write-Host 'cache        : not found - launch the game once to the title screen first'
    } elseif (-not (Test-Path -LiteralPath $live)) {
        Write-Host "cache        : $cacheDir (no language pack yet)"
    } else {
        $liveMd5 = Get-Md5 $live
        $hit = $langs | Where-Object { $_.Want.md5 -eq $liveMd5 } | Select-Object -First 1
        $state = if ($hit) { "$($hit.Name) (latest patch)" } else { 'Japanese, or an older patch' }
        Write-Host "cache        : $cacheDir"
        Write-Host "installed    : $state"
    }

    if (-not $prefabPub) {
        Write-Host 'prefabs      : no prefab patch published for this game build yet'
    } else {
        $done = if (Test-Path -LiteralPath $prefabBackupDir) { @(Get-ChildItem -LiteralPath $prefabBackupDir -Recurse -File).Count } else { 0 }
        $state = if ($done) { "$done bundles replaced here" } else { 'not installed' }
        Write-Host "prefabs      : $($prefabPub.bundles) bundles, $([math]::Round([int64]$prefabPub.size / 1MB, 1)) MB - $state"
    }

    if (-not $inappPub) {
        Write-Host 'in-app       : no in-app build published for this game build yet'
    } else {
        $staged = Join-Path $PatchDataDir $InappFileName
        if (-not (Test-Path -LiteralPath $staged)) {
            $state = 'not downloaded'
        } elseif ((Get-Md5 $staged) -eq $inappPub.md5) {
            $state = 'downloaded, run the watcher before playing'
        } else {
            $state = "an older build (re-run with -FirstLoad)"
        }
        Write-Host "in-app       : $([math]::Round([int64]$inappPub.size / 1MB, 1)) MB - $state"
        $stockMd5 = Get-Prop $inappPub 'stock_md5'
        $stockNow = Get-Md5 $liveInapp
        if ($stockMd5 -and $stockNow -ne $stockMd5) {
            Write-Host 'NOTE: the installed in-app bundle is not the stock file this build targets.'
            Write-Host '      Let DMM verify/repair the game files, then re-run the installer.'
        }
    }

    if ($cacheDir -and $gameHash -and (Split-Path $cacheDir -Leaf) -ne $gameHash) {
        Write-Host 'NOTE: the game has not downloaded the language pack this patch targets yet.'
        Write-Host '      Launch it once to the title screen, close it, then install.'
    }
    Write-Host 'check only - nothing was changed.'
    exit 0
}

# Seeding a folder the game no longer (or doesn't yet) use would silently do nothing.
$cacheDir = Get-LangCacheDir
$target = $gameHash
if ($cacheDir -and $target -and (Split-Path $cacheDir -Leaf) -ne $target -and -not $Force) {
    Write-Host @"
The game's language pack doesn't match this patch's game version yet.
Launch the game once to the title screen (so it downloads its update), close it,
then run this again. (If the game is already up to date, the patch for the new
version isn't out yet. -Force installs anyway.)
"@
    exit 1
}

try { @{ language = $chosen.Code } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding ASCII } catch { }

# --- 4. download + verify the patch -----------------------------------------
$usePrefabs = $Prefabs -and [bool]$prefabPub
$useInapp   = $FirstLoad -and [bool]$inappPub
if ($Prefabs -and -not $prefabPub) { Write-Host 'No prefab patch is published for this game build yet; skipping the prefab bundles.' }
if ($FirstLoad -and -not $inappPub) { Write-Host 'No in-app build is published for this game build yet; skipping the first-load fix.' }
if ($usePrefabs -and $prefabPub.hash -and $gameHash -and $prefabPub.hash -ne $gameHash) {
    Write-Host 'The prefab patch was built for another game build; skipping it. (Re-run after it is republished.)'
    $usePrefabs = $false
}

Write-Host "fetching the $($chosen.Name) patch from the patch-latest release ..."
$art = Get-PatchArtifacts -Version $version -Language $chosen -IncludePrefabs:$usePrefabs -IncludeInapp:$useInapp -Force:$Force
$langBundle = $art.Files.lang
Write-Host "  language bundle : $(Split-Path $langBundle -Leaf)  ($((Get-Item $langBundle).Length) B, md5 $((Get-Md5 $langBundle).Substring(0,8))...)"

# --- 5. stock backups (so DMM repairs are reversible) ------------------------
# Keep clean stock copies so a file check / repair can be satisfied, then re-seeded.
$stockInapp = Join-Path $PatchDataDir 'stock_inapp_assets_all.bundle'
$stockBoot  = Join-Path $PatchDataDir 'stock_boot.config'

# If the live inapp is currently stock (not our EN patch), snapshot it as stock.
# Only the patch's md5 is needed for that, so the 63 MB patch isn't downloaded.
$liveMd5  = Get-Md5 $liveInapp
$patchMd5 = $art.Want.inapp.md5
if ($liveMd5 -ne $patchMd5) {
    Copy-Item -LiteralPath $liveInapp -Destination $stockInapp -Force
    Write-Host 'stock inapp snapshot saved'
} elseif (-not (Test-Path $stockInapp)) {
    Write-Host @"
NOTE: the live inapp bundle is already the EN patch and no stock snapshot exists.
Open DMM GAME PLAYER and let it verify/repair the game files once (or reinstall),
then re-run this installer so a clean stock copy can be captured.
"@
}
Copy-Item -LiteralPath $liveBoot -Destination $stockBoot -Force

# A logging-enabled boot.config (drops the nolog line) so Player.log is written.
$bootLog = Join-Path $PatchDataDir 'boot_logging.config'
Get-Content -LiteralPath $liveBoot | Where-Object { $_ -notmatch '^nolog=' } | Set-Content -LiteralPath $bootLog

# --- 6. seed the language cache ----------------------------------------------
Write-Host "seeding the $($chosen.Name) language bundle into the Unity cache ..."
$res = Install-LanguageCache -LangBundlePath $langBundle -ExpectedSize ([int64]$art.Want.lang.size)
Write-Host "  cache : $($res.CacheDir)"
Write-Host "  __data md5 $($res.DataMd5.Substring(0,8))...  size-ok=$($res.SizeOk)"

if (-not $res.SizeOk) {
    Write-Host "WARNING: seeded __data is not the expected $($art.Want.lang.size) bytes."
}

# --- 7. prefab bundles (persistent, same cache as the language bundle) -------
if ($usePrefabs) {
    Write-Host 'unpacking the English UI prefabs ...'
    if (Test-Path -LiteralPath $prefabDir) { Remove-Item -LiteralPath $prefabDir -Recurse -Force }
    $zip = $art.Files.prefab
    $extracted = $false
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $prefabDir)
        $extracted = $true
    } catch {
        Write-Host "  (ZipFile failed: $($_.Exception.Message); trying Expand-Archive)"
    }
    if (-not $extracted) {
        New-Item -ItemType Directory -Force -Path $prefabDir | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $prefabDir -Force
    }
    $manifest = Get-Content -LiteralPath (Join-Path $prefabDir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "  prefabs : $(@($manifest).Count) bundles (published: $($prefabPub.bundles))"
    & (Get-AssetScript 'Install-PrefabPatch.ps1') -PatchDir $prefabDir
}

# --- 8. in-app bundle + swap watcher (per session) ---------------------------
if ($useInapp) {
    $want = $art.Want.inapp
    if (-not (Get-Prop $want 'stock_md5')) {
        Write-Host 'The published in-app build has no stock_md5; cannot verify which file to swap. Skipping.'
        $useInapp = $false
    }
}
if ($useInapp) {
    # The watcher verifies the installed file against these values, so write the
    # metadata it expects next to the bundle it reads.
    @{ stock_md5  = $art.Want.inapp.stock_md5
       stock_size = (Get-Prop $art.Want.inapp 'stock_size')
       md5        = $art.Want.inapp.md5
       size       = $art.Want.inapp.size
       crc        = (Get-Prop $art.Want.inapp 'crc') } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PatchDataDir $InappMetaName) -Encoding ASCII
    Remove-Item -LiteralPath $stockInapp -Force -ErrorAction SilentlyContinue   # superseded by the published stock md5

    $watcher = Get-AssetScript 'Watch-InappSwap.ps1'
    $cmd = Join-Path $PatchDataDir 'Play-in-English.cmd'
    @"
@echo off
rem MT-EN: swaps the English in-app bundle in, then click Play in DMM GAME PLAYER.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Watch-InappSwap.ps1" -GameDir "$gameDir"
"@ | Set-Content -LiteralPath $cmd -Encoding ASCII

    if ($NoWatcher) {
        Write-Host "in-app bundle ready. Start $cmd before playing (or click Play directly)."
    } else {
        Write-Host 'starting the in-app swap watcher in its own window ...'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$watcher`"", '-GameDir', "`"$gameDir`"") `
            -WorkingDirectory $PatchDataDir -WindowStyle Minimized
    }
}

Write-Host ''
Write-Host "Install complete. To play in $($chosen.Name):"
Write-Host '  click Play in DMM GAME PLAYER (no launcher needed)'
Write-Host '(The language bundle is seeded into the game cache and stays until the game updates.)'
if ($useInapp) {
    Write-Host ''
    Write-Host "First load: run $cmd (or re-run this installer with -FirstLoad) before each"
    Write-Host 'session - the watcher swaps the English in-app bundle in, then click Play.'
}
Write-Host 'Back to Japanese any time: run this installer with -Restore.'

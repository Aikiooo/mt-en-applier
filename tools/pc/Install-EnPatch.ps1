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

  It also rewrites the text the game ships itself, and the redrawn images that
  carry Japanese lettering. The text installs without asking - it is what this
  patch has always done. The images are a visible change to the art, so they get
  the question before their download (the text bundles arrive in their own zip,
  so answering no saves no bandwidth): it defaults to yes, and sixty seconds of
  silence means yes as well.
  - -Prefabs puts the translated UI-prefab bundles into the same Unity cache,
    next to the language bundle (~39.5 MB download, once per game build). They
    carry the ~7,270 strings baked into UI prefabs, including ~400 labels the
    game never overwrites at runtime, and the translated versions of the images
    with Japanese lettering (logos, banners, buttons, tutorial captions).
  - -FirstLoad stages the translated in-app bundle and starts the swap watcher,
    so the first load's title screen is translated too (its tables, its baked
    strings and its title logo). DMM verifies that file before starting the
    game, so it can only be in place while the game runs: the watcher swaps it
    in as the game starts and puts the stock file back on exit. Run it before
    each session through the generated Play-in-<Language>.cmd
    (Play-in-English.cmd, Play-in-French.cmd, ...).
  Each language publishes its own builds of both. One it has not published is
  skipped, and switching languages first puts the original UI prefabs back, so
  nothing of the previous language is left behind.
  -WithAssets answers the image question up front, -NoImages refuses it, and
  -LanguageOnly refuses everything but the language bundle.

  Languages: only the ones published for the current game build are offered.
  With one (English) there is no menu; with several, a short menu appears on
  every run (default: last choice, else the Windows display language, else
  English; Enter or 60 seconds of silence keeps the default) and the choice is
  remembered for the next run. -Language skips the menu.

  Run this once. After that, just click Play in DMM GAME PLAYER (through
  Play-in-<Language>.cmd per session if the in-app half is installed).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1                  # asks about the images
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -WithAssets      # no question, everything
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -NoImages        # text/prefabs, no images
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -LanguageOnly    # language bundle only
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
    # Rewrite the text baked into the cached UI prefabs (persistent).
    [switch]$Prefabs,
    # Stage the translated in-app bundle and start its swap watcher (per session).
    [switch]$FirstLoad,
    # -Prefabs + -FirstLoad.
    [switch]$WithAssets,
    # Language bundle only: no prompt, no asset patching.
    [switch]$LanguageOnly,
    # Text and prefabs, but not the redrawn images.
    [switch]$NoImages,
    # Do not start the watcher (used by -Check; the caller may do it itself).
    [switch]$NoWatcher
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot      # absolute even when invoked as -File tools\pc\...
Import-Module (Join-Path $here 'MT.EnPatch.psm1') -Force

if ($WithAssets) { $Prefabs = $true; $FirstLoad = $true }
if ($LanguageOnly) { $Prefabs = $false; $FirstLoad = $false }
# The text side is what this patch has always done and is no more invasive than
# it was, so it installs without asking. The images are the new, visible change,
# so they are the thing the question below is about.
if (-not ($Prefabs -or $FirstLoad) -and -not $LanguageOnly) { $Prefabs = $true; $FirstLoad = $true }

# Ask before doing the part that rewrites the game's own shipped text, but never
# block a run without a console on it: the default is yes, and 60 seconds of
# silence means yes too.
function Read-YesNo([string]$Question, [int]$TimeoutSec, [bool]$Default) {
    if (-not ([Environment]::UserInteractive) -or [Console]::IsInputRedirected) {
        Write-Host "$Question -> yes (nothing to ask on)"
        return $Default
    }
    Write-Host ''
    Write-Host "  $Question"
    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $left = [int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
            Write-Host ("`r    [Y] yes (default)   [N] no    ... $left s   ") -NoNewline
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                Write-Host ''
                if ($k.Key -eq 'Enter' -or $k.Key -eq 'Y') { return $true }
                if ($k.Key -eq 'N') { return $false }
            }
            Start-Sleep -Milliseconds 200
        }
    } catch {
        Write-Host ''
        Write-Host "  (could not read the console: $($_.Exception.Message))"
        return $Default
    }
    Write-Host ''
    Write-Host "  no answer in $TimeoutSec s -> yes"
    return $Default
}

# Pick one of several items with a digit key; Enter or $TimeoutSec of silence
# keeps the default. Same never-block rule as Read-YesNo.
function Read-Choice([string]$Question, [string[]]$Items, [int]$DefaultIndex, [int]$TimeoutSec) {
    Write-Host ''
    Write-Host "  $Question"
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $mark = if ($i -eq $DefaultIndex) { '  (default)' } else { '' }
        Write-Host ("    {0}) {1}{2}" -f ($i + 1), $Items[$i], $mark)
    }
    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $left = [int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
            Write-Host ("`r    choose 1-{0}, Enter = {1}   ... {2} s   " -f $Items.Count, ($DefaultIndex + 1), $left) -NoNewline
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Enter') { Write-Host ''; return $DefaultIndex }
                $n = 0
                if ([int]::TryParse([string]$k.KeyChar, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
                    Write-Host ''
                    return $n - 1
                }
            }
            Start-Sleep -Milliseconds 200
        }
    } catch {
        Write-Host ''
        Write-Host "  (could not read the console: $($_.Exception.Message))"
        return $DefaultIndex
    }
    Write-Host ''
    Write-Host "  no answer in $TimeoutSec s -> $($Items[$DefaultIndex])"
    return $DefaultIndex
}

$prefabDir = Join-Path $PatchDataDir 'prefab-patch'
$prefabBackupDir = Join-Path $PatchDataDir 'prefab-backup'
$settingsPath = Join-Path $PatchDataDir 'settings.json'

# Where one language's in-app build lives here, and the command that plays it.
function Get-InappPaths($Lang) {
    $file = Get-Prop $Lang.Inapp 'file'
    if (-not $file) { $file = "inapp_assets_all_$($Lang.Code).bundle" }
    $bundle = Join-Path $PatchDataDir $file
    return @{ Bundle = $bundle; Meta = "$bundle.json"; Cmd = (Join-Path $PatchDataDir "Play-in-$($Lang.Label).cmd") }
}

# Unpack a published tree into a fresh folder and swap it in, so a failed extract
# cannot take the previous tree (and its manifest) with it. Returns nothing:
# "return , $array" nests the array through the caller in Windows PowerShell 5.1,
# so callers read the manifest from disk instead.
function Expand-PatchZip([string]$Zip, [string]$Dest) {
    $newDir = "$Dest.new"
    if (Test-Path -LiteralPath $newDir) { Remove-Item -LiteralPath $newDir -Recurse -Force }
    $ok = $false
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $newDir)
        $ok = $true
    } catch {
        Write-Host "  (ZipFile failed: $($_.Exception.Message); trying Expand-Archive)"
    }
    if (-not $ok) {
        New-Item -ItemType Directory -Force -Path $newDir | Out-Null
        Expand-Archive -LiteralPath $Zip -DestinationPath $newDir -Force
    }
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
    Move-Item -LiteralPath $newDir -Destination $Dest
}

function Plural([int]$N, [string]$Word) {
    if ($N -eq 1) { return "1 $Word" }
    return "$N ${Word}s"
}

# The helper scripts run from wherever they are, but Play-in-<Language>.cmd runs
# whatever sits next to it in PatchDataDir, so a copy has to be there too (the
# one-line installer fetches them into ...\pc\installer, not into ...\pc).
function Get-AssetScript([string]$Name) {
    foreach ($p in @((Join-Path $here $Name), (Join-Path $PatchDataDir $Name))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    New-Item -ItemType Directory -Force -Path $PatchDataDir | Out-Null
    $dst = Join-Path $PatchDataDir $Name
    if ($Name -ne 'MT.EnPatch.psm1') { Copy-Item -LiteralPath (Join-Path $here 'MT.EnPatch.psm1') -Destination $PatchDataDir -Force }
    Write-Host "  fetching $Name ..."
    Get-RemoteFile -Uri "$ReleaseBase/$Name" -Destination $dst
    return $dst
}

# Keep the copies in PatchDataDir current: Play-in-<Language>.cmd runs those, and
# the one they were copied from is replaced by every update.
function Install-AssetScripts {
    foreach ($name in @('Watch-InappSwap.ps1', 'MT.EnPatch.psm1')) {
        $src = Get-AssetScript $name
        $dst = Join-Path $PatchDataDir $name
        if ($src -ne $dst) { Copy-Item -LiteralPath $src -Destination $dst -Force }
    }
    return (Join-Path $PatchDataDir 'Watch-InappSwap.ps1')
}

# Repair whatever a crashed session left behind and return the watcher's output.
# Asked unconditionally rather than second-guessed here: the watcher knows where
# its own staging folder is, including the fallback inside StreamingAssets.
function Invoke-WatcherRepair([string]$KnownGameDir) {
    $watcher = Get-AssetScript 'Watch-InappSwap.ps1'
    # Named parameters, not an array splat: splatted arrays bind positionally.
    if ($KnownGameDir) { return (& $watcher -RestoreOnly -GameDir $KnownGameDir) -join "`n" }
    return (& $watcher -RestoreOnly) -join "`n"
}

# Returns the prefab script's result object ($null when there is nothing to do).
# The backups are what restoring walks, so they decide whether there is anything
# to do (the unpacked tree can be gone, or never have been unpacked here).
function Invoke-PrefabRestore([switch]$ReportOnly) {
    if (-not (Test-Path -LiteralPath $prefabBackupDir)) { return $null }
    return & (Get-AssetScript 'Install-PrefabPatch.ps1') -PatchDir $prefabDir -Restore -Check:$ReportOnly
}

# Nothing left armed: the in-app file itself is only a download, but the command
# that swaps it in and the metadata it verifies against are part of the patch.
# -Keep (Get-InappPaths of the language being installed) spares that language's
# files, so only what other languages left behind goes.
function Remove-InappStaging([string]$KnownGameDir, $Keep) {
    $stockMd5 = $null
    $metas = @(Get-ChildItem -LiteralPath $PatchDataDir -Filter 'inapp_assets_all_*.bundle.json' -File -ErrorAction SilentlyContinue)
    foreach ($m in $metas) {
        try { if (-not $stockMd5) { $stockMd5 = (Get-Content -LiteralPath $m.FullName -Raw | ConvertFrom-Json).stock_md5 } } catch { }
    }
    $armed = @($metas) + @(Get-ChildItem -LiteralPath $PatchDataDir -Filter 'Play-in-*.cmd' -File -ErrorAction SilentlyContinue)
    foreach ($f in $armed) {
        if ($Keep -and ($f.FullName -eq $Keep.Meta -or $f.FullName -eq $Keep.Cmd)) { continue }
        Remove-Item -LiteralPath $f.FullName -Force
    }
    if (-not $KnownGameDir) { return }
    $stage = Join-Path (Split-Path $KnownGameDir -Parent) 'mt-en-staging'
    if (-not (Test-Path -LiteralPath $stage)) { return }
    $keepLeaf = if ($Keep) { Split-Path $Keep.Bundle -Leaf }
    foreach ($f in @(Get-ChildItem -LiteralPath $stage -Filter 'inapp_assets_all*.bundle' -File)) {
        $p = $f.FullName
        if ($keepLeaf -and $f.Name -eq $keepLeaf) { continue }
        # The stock copy can be the only one left after a crashed swap: drop it
        # only once the installed bundle is provably the stock one.
        if ($p -like '*stock*') {
            if ($Keep) { continue }   # the watcher of the kept language owns it
            $livePath = Join-Path $KnownGameDir $InappRelPath
            $isStock = $stockMd5 -and (Test-Path -LiteralPath $livePath) -and ((Get-Md5 $livePath) -eq $stockMd5)
            if (-not $isStock) {
                Write-Host "NOTE: keeping $p (the installed in-app bundle is not the stock file)."
                continue
            }
        }
        Remove-Item -LiteralPath $p -Force
    }
    if ((Test-Path -LiteralPath $stage) -and -not (Get-ChildItem -LiteralPath $stage -Force)) {
        Remove-Item -LiteralPath $stage -Force
    }
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
    try {
        $repair = Invoke-WatcherRepair $knownGame
        if ($repair -match 'stock in-app bundle (left over|back)|Put the stock') {
            Write-Host 'Repaired an in-app swap left behind by a previous session.'
        }
    } catch { Write-Host "NOTE: could not repair the in-app staging folder: $($_.Exception.Message)" }
    Remove-InappStaging $knownGame

    $prefab = Invoke-PrefabRestore
    if ($prefab) {
        if ($prefab.failed) {
            Write-Host "NOTE: $($prefab.failed) UI prefabs could not be restored; see the counts above."
        } elseif ($prefab.restored) {
            Write-Host "Restored: $($prefab.restored) cached UI prefabs are Japanese again."
        } elseif ($prefab.already -eq 0) {
            Write-Host 'No cached UI prefabs needed restoring.'
        } else {
            Write-Host 'Restored: the cached UI prefabs were already Japanese.'
        }
    }

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
# Repair a swap a crashed session left behind, before touching anything else.
# Never in -Check mode: reporting must not change files.
if (-not $Check) {
    try {
        $repair = Invoke-WatcherRepair $gameDir
        if ($repair -match 'stock in-app bundle (left over|back)|Put the stock') {
            Write-Host 'repaired an in-app swap left behind by a previous session'
        }
    } catch { Write-Host "NOTE: could not check the in-app staging folder: $($_.Exception.Message)" }
}

# The repair above can put a stock bundle back, so check only after it.
foreach ($f in @($liveInapp, $liveBoot)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "ERROR: expected game file missing: $f"
        Write-Host 'Start the game once from DMM GAME PLAYER so it restores its files, close it, then run this again.'
        exit 1
    }
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

function Read-SavedSettings {
    try {
        if (Test-Path -LiteralPath $settingsPath) {
            return Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    } catch { }
    return $null
}
$saved = Read-SavedSettings

if ($Language) {
    $chosen = $langs | Where-Object { $_.Code -eq $Language } | Select-Object -First 1
    if (-not $chosen) {
        Write-Host "Language '$Language' isn't published for this game version. Available: $(($langs | ForEach-Object { $_.Code }) -join ', ')"
        exit 1
    }
} elseif ($langs.Count -eq 1) {
    $chosen = $langs[0]
} else {
    $savedCode = Get-Prop $saved 'language'
    $default = $langs | Where-Object { $_.Code -eq $savedCode } | Select-Object -First 1
    $from = 'last time'
    # English (listed first) until the player picks another language once.
    if (-not $default) { $default = $langs[0]; $from = 'default' }
    $chosen = $default
    $canAsk = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    if ($Check) {
        Write-Host "languages    : $(($langs | ForEach-Object { $_.Name }) -join ', ') (would default to $($default.Name))"
    } elseif ($canAsk) {
        # Asked on every interactive run, so a language published after the first
        # install (or a change of mind) is one keypress away; the default is the
        # last choice, so re-running after a game update is still just Enter.
        $defIdx = [array]::IndexOf(@($langs | ForEach-Object { $_.Code }), $default.Code)
        $pick = Read-Choice "Patch language ($($from): $($default.Name))" @($langs | ForEach-Object { $_.Name }) $defIdx 60
        $chosen = $langs[$pick]
        Write-Host "language : $($chosen.Name)"
    } else {
        Write-Host "language : $($chosen.Name) ($from)"
    }
}

# Each language publishes its own UI prefab and in-app builds. A language that
# has not published one gets none, and nothing another language left must stay:
# a French language pack under an English title screen is worse than either.
$prefabPub = $chosen.Prefab
$imagePub  = $chosen.Images
$inappPub  = $chosen.Inapp
$inapp     = Get-InappPaths $chosen
$inappCmd  = $inapp.Cmd
$inappMeta = $inapp.Meta
$gameHash  = Get-Prop (Get-Prop $version 'pc').language_ja_en 'hash'
$prevCode  = Get-Prop $saved 'language'
# The prefab installer replaces bundles it wrote before, but a bundle only the
# previous language patched, or the images when they are declined this time,
# would stay in that language: the originals go back first (step 7).
$switching = $prevCode -and $prevCode -ne $chosen.Code -and (Test-Path -LiteralPath $prefabBackupDir)

if (-not $prefabPub -and $Prefabs) {
    Write-Host "No UI prefab build is published for $($chosen.Name) yet; skipping it."
}
if (-not $inappPub -and $FirstLoad) {
    Write-Host "No in-app build is published for $($chosen.Name) yet; skipping it."
}
if ($Check) {
    if ($switching) { Write-Host "switching    : from '$prevCode' - the installed UI prefabs would be put back first" }
} else {
    # The other languages' launchers would swap their title screen in.
    Remove-InappStaging $gameDir -Keep $(if ($inappPub) { $inapp })
    if (Test-Path -LiteralPath $inappCmd) { [void](Install-AssetScripts) }   # the .cmd runs these; keep them current
}

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
        # Count what is actually in place, not what was installed once: a
        # restore leaves the backups behind.
        $done = 0
        $doneImages = 0
        $imageOnly = 0
        $cache = Get-UnityCachePublisherDir
        $manifestPath = Join-Path $prefabDir 'manifest.json'
        $imageManifestPath = Join-Path $prefabDir 'manifest-images.json'
        if (Test-Path -LiteralPath $manifestPath) {
            # Assign then wrap: no @() around the pipeline, because Windows
            # PowerShell 5.1 does not enumerate a JSON array out of
            # ConvertFrom-Json, so @() would make it one item.
            $prefabManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($e in @($prefabManifest)) {
                if (-not $cache) { continue }
                $t = Join-Path $cache ($e.rel -replace '/', '\')
                if ((Test-Path -LiteralPath $t) -and ((Get-Md5 $t) -eq $e.out_md5)) { $done++ }
            }
        }
        if (Test-Path -LiteralPath $imageManifestPath) {
            $imageManifest = Get-Content -LiteralPath $imageManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $imageManifest = @($imageManifest)
            $imageOnly = $imageManifest.Count
            if ($cache) {
                foreach ($e in $imageManifest) {
                    $t = Join-Path $cache ($e.rel -replace '/', '\')
                    if ((Test-Path -LiteralPath $t) -and ((Get-Md5 $t) -eq $e.out_md5)) { $doneImages++ }
                }
            }
        }
        $state = if ($done) { "$done of $($prefabPub.bundles) text bundles in place" } else { 'not installed' }
        Write-Host "prefabs      : $($prefabPub.bundles) bundles, $([math]::Round([int64]$prefabPub.size / 1MB, 1)) MB - $state"
        if ($imagePub) {
            $imageState = if ($doneImages) { "$doneImages of $($imagePub.bundles) in place" } else { 'not installed' }
            Write-Host "images       : $($imagePub.bundles) bundles, $([math]::Round([int64]$imagePub.size / 1MB, 1)) MB - $imageState"
        }
    }

    if (-not $inappPub) {
        Write-Host 'in-app       : no in-app build published for this game build yet'
    } else {
        $staged = $inapp.Bundle
        if (-not (Test-Path -LiteralPath $staged)) {
            $state = 'not downloaded'
        } elseif ((Get-Md5 $staged) -eq $inappPub.md5) {
            $state = if (Test-Path -LiteralPath $inappCmd) { "ready, start it with $(Split-Path $inappCmd -Leaf)" } else { 'downloaded, run -FirstLoad' }
        } else {
            $state = 'an older build (re-run with -FirstLoad)'
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

# Remember the choice and the folder that was found: the watcher falls back to
# this when DMM's config does not name the game, which keeps the game path out
# of Play-in-<Language>.cmd (it is written as ASCII).
try {
    [IO.File]::WriteAllText($settingsPath,
        (@{ language = $chosen.Code; game_dir = $gameDir } | ConvertTo-Json),
        (New-Object System.Text.UTF8Encoding($false)))
} catch { }

# --- 4. download + verify the patch -----------------------------------------
$usePrefabs = $Prefabs -and [bool]$prefabPub
$useInapp   = $FirstLoad -and [bool]$inappPub
# Menus and images built for an earlier pack still go in: the prefab installer
# skips each bundle a game update changed since (its src_md5 no longer matches).
foreach ($p in @(@('menus', $prefabPub), @('images', $imagePub))) {
    $h = Get-Prop $p[1] 'hash'
    if ($h -and $gameHash -and $h -ne $gameHash) {
        Write-Host "$($p[0]) were built for an earlier language pack ($($h.Substring(0, 8))); the bundles a game update changed since are skipped."
    }
}

Write-Host "fetching the $($chosen.Name) patch from the patch-latest release ..."
$art = Get-PatchArtifacts -Version $version -Language $chosen -IncludePrefabs:$usePrefabs -IncludeInapp:$useInapp -Force:$Force
$langBundle = $art.Files.lang
Write-Host "  language bundle : $(Split-Path $langBundle -Leaf)  ($((Get-Item $langBundle).Length) B, md5 $((Get-Md5 $langBundle).Substring(0,8))...)"

# --- 5. stock backups (so DMM repairs are reversible) ------------------------
# Keep clean stock copies so a file check / repair can be satisfied, then re-seeded.
$stockInapp = Join-Path $PatchDataDir 'stock_inapp_assets_all.bundle'
$stockBoot  = Join-Path $PatchDataDir 'stock_boot.config'

if ($useInapp) {
    # The published stock_md5 supersedes the snapshot, and the staged file is
    # 61 MB: do not copy it in only to delete it two steps later.
    Remove-Item -LiteralPath $stockInapp -Force -ErrorAction SilentlyContinue
} else {
    # If the live inapp is currently stock (not our EN patch), snapshot it as stock.
    # Only the patch's md5 is needed for that, so the 61 MB patch isn't downloaded.
    # Any language's build counts as patched: a crashed session in another one
    # must not be snapshotted as stock.
    $liveMd5  = Get-Md5 $liveInapp
    $patched  = @($langs | ForEach-Object { Get-Prop $_.Inapp 'md5' } | Where-Object { $_ })
    if ($patched -notcontains $liveMd5) {
        Copy-Item -LiteralPath $liveInapp -Destination $stockInapp -Force
        Write-Host 'stock inapp snapshot saved'
    } elseif (-not (Test-Path $stockInapp)) {
        Write-Host @"
NOTE: the live inapp bundle is already a patched build and no stock snapshot exists.
Open DMM GAME PLAYER and let it verify/repair the game files once (or reinstall),
then re-run this installer so a clean stock copy can be captured.
"@
    }
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
if ($switching) {
    Write-Host "putting the original UI prefabs back before installing $($chosen.Name) ..."
    $prefab = Invoke-PrefabRestore
    if ($prefab -and $prefab.failed) { Write-Host "NOTE: $($prefab.failed) UI prefabs could not be restored." }
    # Nothing of the previous language is left to report on.
    Remove-Item -LiteralPath $prefabDir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($usePrefabs) {
    Write-Host "unpacking the $($chosen.Label) UI prefabs ..."
    Expand-PatchZip -Zip $art.Files.prefab -Dest $prefabDir
    $manifest = Get-Content -LiteralPath (Join-Path $prefabDir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest = @($manifest)
    $textCount = @($manifest | Where-Object { (Get-Prop $_ 'changed') }).Count
    Write-Host "  text bundles : $textCount (published: $($prefabPub.bundles))"
    try {
        # The text side installs without asking: it is what the patch has always
        # done.
        $res = & (Get-AssetScript 'Install-PrefabPatch.ps1') -PatchDir $prefabDir
        if ($res -and $res.missing) { Write-Host 'Some UI bundles were not in the cache yet (see above).' }
    } catch {
        # The language bundle is already seeded; the in-app half below is
        # independent, so a prefab failure must not take it down too.
        Write-Host "NOTE: the prefab install stopped: $($_.Exception.Message)"
    }

    # The redrawn images are a separate download, so the question comes first and
    # a "no" never fetches them.
    if ($imagePub) {
        $withImages = -not $NoImages
        if ($withImages -and -not $WithAssets) {
            $withImages = Read-YesNo "Also install the $($chosen.Label) images? ($(Plural ([int]$imagePub.bundles) 'bundle'): logos, banners, badges, tutorial captions; $([math]::Round([int64]$imagePub.size / 1MB, 1)) MB download)" 60 $true
        }
        if ($withImages) {
            Write-Host "fetching the $($chosen.Label) images ($([math]::Round([int64]$imagePub.size / 1MB, 1)) MB) ..."
            $imgZip = Get-VerifiedFile -Name (Get-Prop $imagePub 'file') -Want $imagePub -Force:$Force
            Expand-PatchZip -Zip $imgZip -Dest (Join-Path $PatchDataDir 'prefab-images')
            try {
                $res = & (Get-AssetScript 'Install-PrefabPatch.ps1') -PatchDir (Join-Path $PatchDataDir 'prefab-images')
                if ($res -and $res.missing) { Write-Host 'Some image bundles were not in the cache yet (see above).' }
            } catch {
                Write-Host "NOTE: the image install stopped: $($_.Exception.Message)"
            }
        } else {
            # Not "left Japanese": they may already be installed from an earlier
            # run, and answering no simply leaves them as they are.
            Write-Host "$($chosen.Label) images skipped. Add them later with -WithAssets (or by answering yes)."
        }
    }
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
        ConvertTo-Json | Set-Content -LiteralPath $inappMeta -Encoding ASCII

    $watcher = Install-AssetScripts
    # No -GameDir here: the watcher reads it from DMM's config or from
    # settings.json, and this file is written as ASCII.
    @"
@echo off
rem MT-EN: stages the $($chosen.Label) in-app bundle, then click Play in DMM GAME PLAYER.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Watch-InappSwap.ps1" -EnglishBundle "%~dp0$(Split-Path $inapp.Bundle -Leaf)"
if errorlevel 1 pause
"@ | Set-Content -LiteralPath $inappCmd -Encoding ASCII

    if ($NoWatcher) {
        Write-Host "in-app bundle ready. Start $inappCmd before playing (or click Play directly)."
    } else {
        Write-Host 'starting the in-app swap watcher in its own window ...'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$watcher`"", '-GameDir', "`"$gameDir`"",
                            '-EnglishBundle', "`"$($inapp.Bundle)`"") `
            -WorkingDirectory $PatchDataDir -WindowStyle Minimized
    }
}

Write-Host ''
Write-Host "Install complete. To play in $($chosen.Name):"
if ($useInapp) {
    Write-Host "  start the game with $inappCmd, then click Play in DMM GAME PLAYER"
    Write-Host "  (the watcher swaps the $($chosen.Label) in-app bundle in, and puts the stock file"
    Write-Host '   back when you close the game, so DMM always finds its own file)'
} else {
    Write-Host '  click Play in DMM GAME PLAYER (no launcher needed)'
}
Write-Host '(The language bundle is seeded into the game cache and stays until the game updates.)'
Write-Host 'Back to Japanese any time: run this installer with -Restore.'

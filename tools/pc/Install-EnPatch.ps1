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
  game's own shipped text, which is why those are opt-in and English-only:
  - -Prefabs puts the English UI-prefab bundles into the same Unity cache, next
    to the language bundle (~40 MB download, once per game build). They carry
    the ~7,270 strings baked into UI prefabs, including ~400 labels the game
    never overwrites at runtime.
  - -FirstLoad stages the English in-app bundle and starts the swap watcher, so
    the first load's title screen is English too. DMM verifies that file before
    starting the game, so it can only be in place while the game runs: the
    watcher swaps it in as the game starts and puts the stock file back on exit.
    Run it before each session through the generated Play-in-English.cmd.

  Languages: only the ones published for the current game build are offered.
  With one (English) there is no prompt; with several, a short menu appears
  (default: last choice, else the Windows display language, else English) and
  the choice is remembered for the next run. -Language skips the menu.

  Run this once. After that, just click Play in DMM GAME PLAYER (through
  Play-in-English.cmd per session if -FirstLoad was used).

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
$inappCmd = Join-Path $PatchDataDir 'Play-in-English.cmd'
$inappMeta = Join-Path $PatchDataDir $InappMetaName

# The helper scripts run from wherever they are, but Play-in-English.cmd runs
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

function Install-AssetScripts {
    foreach ($name in @('Watch-InappSwap.ps1', 'MT.EnPatch.psm1')) {
        $src = Get-AssetScript $name
        $dst = Join-Path $PatchDataDir $name
        if ($src -ne $dst) { Copy-Item -LiteralPath $src -Destination $dst -Force }
    }
    return (Join-Path $PatchDataDir 'Watch-InappSwap.ps1')
}

# Restore is also the repair path: a crash can leave the English bundle in place
# with the stock one beside it.
function Test-WatcherLeftovers([string]$KnownGameDir) {
    if (-not $KnownGameDir) { return $false }
    $stage = Join-Path (Split-Path $KnownGameDir -Parent) 'mt-en-staging'
    foreach ($p in @((Join-Path $stage 'inapp_assets_all.stock.bundle'),
                     (Join-Path $KnownGameDir "$InappRelPath.en"),
                     (Join-Path $KnownGameDir "$InappRelPath.stock"))) {
        if (Test-Path -LiteralPath $p) { return $true }
    }
    return $false
}

function Invoke-WatcherRepair([string]$KnownGameDir) {
    $watcher = Get-AssetScript 'Watch-InappSwap.ps1'
    # Named parameters, not an array splat: splatted arrays bind positionally.
    if ($KnownGameDir) { & $watcher -RestoreOnly -GameDir $KnownGameDir | Out-Null }
    else { & $watcher -RestoreOnly | Out-Null }
}

function Invoke-PrefabRestore {
    if (-not (Test-Path -LiteralPath $prefabDir)) { return $false }
    try {
        & (Get-AssetScript 'Install-PrefabPatch.ps1') -PatchDir $prefabDir -Restore
        Write-Host 'Restored: the cached UI prefabs are Japanese again.'
    } catch {
        # No $LASTEXITCODE check: a script invoked with & does not set it.
        Write-Host "NOTE: could not restore the UI prefabs: $($_.Exception.Message)"
        Write-Host '      The backups are kept, so a later -Restore can finish the job.'
    }
    return $true
}

# Nothing left armed: the in-app file is a download, but the command that swaps
# it in and the metadata it verifies against are part of the patch.
function Remove-InappStaging([string]$KnownGameDir) {
    foreach ($p in @($inappCmd, $inappMeta)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    if ($KnownGameDir) {
        $stage = Join-Path (Split-Path $KnownGameDir -Parent) 'mt-en-staging'
        foreach ($p in @((Join-Path $stage 'inapp_assets_all_en.bundle'),
                         (Join-Path $stage 'inapp_assets_all.stock.bundle'))) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
        }
        if ((Test-Path -LiteralPath $stage) -and -not (Get-ChildItem -LiteralPath $stage -Force)) {
            Remove-Item -LiteralPath $stage -Force
        }
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
    if (Test-WatcherLeftovers $knownGame) {
        try { Invoke-WatcherRepair $knownGame }
        catch { Write-Host "NOTE: could not put the stock in-app bundle back: $($_.Exception.Message)" }
    }
    Remove-InappStaging $knownGame

    if (Invoke-PrefabRestore) { }   # reports its own outcome

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

# Repair a swap a crashed session left behind, before touching anything else.
if (Test-WatcherLeftovers $gameDir) {
    try { Invoke-WatcherRepair $gameDir; Write-Host 'repaired an in-app swap left behind by a previous session' }
    catch { Write-Host "NOTE: could not repair the in-app staging folder: $($_.Exception.Message)" }
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

# The UI prefabs and the in-app bundle are English builds; a Spanish language
# pack with an English title screen would be worse than either alone. Anything a
# previous English run left in place is undone here, so the result is fully the
# chosen language.
if (($Prefabs -or $FirstLoad) -and $chosen.Code -ne 'en') {
    Write-Host "The UI prefab and in-app builds are English-only; skipping them for $($chosen.Name)."
    if (Test-Path -LiteralPath $prefabDir) { Invoke-PrefabRestore }
    Remove-InappStaging $gameDir
    $Prefabs = $false
    $FirstLoad = $false
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

    if ($chosen.Code -ne 'en') {
        Write-Host 'prefabs      : English only - not offered for this language'
        Write-Host 'in-app       : English only - not offered for this language'
    } else {
        if (-not $prefabPub) {
            Write-Host 'prefabs      : no prefab patch published for this game build yet'
        } else {
            # Count what is actually in place, not what was installed once: a
            # restore leaves the backups behind.
            $done = 0
            $manifestPath = Join-Path $prefabDir 'manifest.json'
            if (Test-Path -LiteralPath $manifestPath) {
                $cache = Get-UnityCachePublisherDir
                foreach ($e in (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                    $t = Join-Path $cache ($e.rel -replace '/', '\')
                    if ((Test-Path -LiteralPath $t) -and ((Get-Md5 $t) -eq $e.out_md5)) { $done++ }
                }
            }
            $state = if ($done) { "$done of $($prefabPub.bundles) bundles in place" } else { 'not installed' }
            Write-Host "prefabs      : $($prefabPub.bundles) bundles, $([math]::Round([int64]$prefabPub.size / 1MB, 1)) MB - $state"
        }

        if (-not $inappPub) {
            Write-Host 'in-app       : no in-app build published for this game build yet'
        } else {
            $staged = Join-Path $PatchDataDir $InappFileName
            if (-not (Test-Path -LiteralPath $staged)) {
                $state = 'not downloaded'
            } elseif ((Get-Md5 $staged) -eq $inappPub.md5) {
                $state = if (Test-Path -LiteralPath $inappCmd) { 'ready, start it with Play-in-English.cmd' } else { 'downloaded, run -FirstLoad' }
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

if ($useInapp) {
    # The published stock_md5 supersedes the snapshot, and the staged file is
    # 63 MB: do not copy it in only to delete it two steps later.
    Remove-Item -LiteralPath $stockInapp -Force -ErrorAction SilentlyContinue
} else {
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
    # The old tree is replaced, so a failed restore cannot be resurrected from a
    # stale manifest, and the backups are kept for a later -Restore.
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
    try {
        & (Get-AssetScript 'Install-PrefabPatch.ps1') -PatchDir $prefabDir
    } catch {
        # The language bundle is already seeded; the in-app half below is
        # independent, so a prefab failure must not take it down too.
        Write-Host "NOTE: the prefab install stopped: $($_.Exception.Message)"
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
    # No -GameDir here: the watcher finds the game from DMM's config, and this
    # file is written as ASCII, so a non-ASCII game path would be mangled.
    @"
@echo off
rem MT-EN: stages the English in-app bundle, then click Play in DMM GAME PLAYER.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Watch-InappSwap.ps1"
if errorlevel 1 pause
"@ | Set-Content -LiteralPath $inappCmd -Encoding ASCII

    if ($NoWatcher) {
        Write-Host "in-app bundle ready. Start $inappCmd before playing (or click Play directly)."
    } else {
        Write-Host 'starting the in-app swap watcher in its own window ...'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$watcher`"", '-GameDir', "`"$gameDir`"") `
            -WorkingDirectory $PatchDataDir -WindowStyle Minimized
    }
}

Write-Host ''
Write-Host "Install complete. To play in $($chosen.Name):"
if ($useInapp) {
    Write-Host "  start the game with $inappCmd, then click Play in DMM GAME PLAYER"
    Write-Host '  (the watcher swaps the English in-app bundle in, and puts the stock file'
    Write-Host '   back when you close the game, so DMM always finds its own file)'
} else {
    Write-Host '  click Play in DMM GAME PLAYER (no launcher needed)'
}
Write-Host '(The language bundle is seeded into the game cache and stays until the game updates.)'
Write-Host 'Back to Japanese any time: run this installer with -Restore.'

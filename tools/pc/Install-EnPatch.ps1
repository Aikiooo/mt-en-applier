<#
.SYNOPSIS
  One-command installer for the Mushoku Tensei PC English patch (DMM client).

.DESCRIPTION
  - Downloads the latest EN patch (language bundle + inapp patch) from the
    rolling 'patch-latest' GitHub release and verifies size + md5.
  - Seeds the exact-size, CRC-forged language bundle into the Unity
    Addressables cache (__data). The catalog is left untouched; editing the
    catalog is what triggers the "Failed to acquire resources" integrity error.
  - Captures clean stock copies (inapp bundle + boot.config) so DMM file
    repairs stay reversible and a future launcher can satisfy the file check.

  Run this once. After that, just click Play in DMM GAME PLAYER.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -GameDir 'D:\Games\mushoku_coe_cl' -Force
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -Check   # report only, change nothing
#>
param(
    [string]$GameDir,
    [switch]$Force,
    # Report what an install would do (game, cache, current language), change nothing.
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'MT.EnPatch.psm1') -Force

Write-Host 'MT-EN PC installer'

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

if ($Check) {
    # Read-only: no downloads besides version.json (kept in memory), no writes.
    $v = Invoke-RestMethod -UseBasicParsing -Uri "$ReleaseBase/$VersionFile"
    $want = $v.pc.language_ja_en
    Write-Host "latest patch : $($want.size) B, md5 $($want.md5.Substring(0,8))..., game build $($v.game_version)"
    $cacheDir = Get-LangCacheDir
    $live = if ($cacheDir) { Join-Path $cacheDir '__data' }
    if (-not $cacheDir) {
        Write-Host 'cache        : not found - launch the game once to the title screen first'
    } elseif (-not (Test-Path -LiteralPath $live)) {
        Write-Host "cache        : $cacheDir (no language pack yet)"
    } else {
        $state = if ((Get-Md5 $live) -eq $want.md5) { 'English (latest patch)' } else { 'Japanese, or an older patch' }
        Write-Host "cache        : $cacheDir"
        Write-Host "installed    : $state"
    }
    if ($cacheDir -and $want.hash -and (Split-Path $cacheDir -Leaf) -ne $want.hash) {
        Write-Host 'NOTE: the game has not downloaded the language pack this patch targets yet.'
        Write-Host '      Launch it once to the title screen, close it, then install.'
    }
    Write-Host 'check only - nothing was changed.'
    exit 0
}

# --- 2. download + verify the patch -----------------------------------------
Write-Host 'fetching latest patch from the patch-latest release ...'
$art = Get-PatchArtifacts -Force:$Force
$langBundle  = $art.Files.lang
$inappPatch  = $art.Files.inapp
Write-Host "  language bundle : $(Split-Path $langBundle -Leaf)  ($((Get-Item $langBundle).Length) B, md5 $((Get-Md5 $langBundle).Substring(0,8))...)"
Write-Host "  inapp patch     : $(Split-Path $inappPatch -Leaf)  ($((Get-Item $inappPatch).Length) B)"

# --- 3. stock backups (so DMM repairs are reversible; kept for a future launcher) ----
# Keep clean stock copies so a file check / repair can be satisfied, then re-seeded.
$stockInapp = Join-Path $PatchDataDir 'stock_inapp_assets_all.bundle'
$stockBoot  = Join-Path $PatchDataDir 'stock_boot.config'

# If the live inapp is currently stock (not our EN patch), snapshot it as stock.
$liveMd5  = Get-Md5 $liveInapp
$patchMd5 = Get-Md5 $inappPatch
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

# --- 4. seed the language cache ----------------------------------------------
Write-Host 'seeding EN language bundle into the Unity cache ...'
$res = Install-LanguageCache -LangBundlePath $langBundle -ExpectedSize ([int64]$art.Want.lang.size)
Write-Host "  cache : $($res.CacheDir)"
Write-Host "  __data md5 $($res.DataMd5.Substring(0,8))...  size-ok=$($res.SizeOk)"

if (-not $res.SizeOk) {
    Write-Host "WARNING: seeded __data is not the expected $($art.Want.lang.size) bytes."
}

Write-Host ''
Write-Host 'Install complete. To play in English:'
Write-Host '  click Play in DMM GAME PLAYER (no launcher needed)'
Write-Host '(The language bundle is seeded into the game cache and stays until the game updates.)'

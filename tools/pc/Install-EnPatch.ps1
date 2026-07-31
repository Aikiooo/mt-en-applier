<#
.SYNOPSIS
  One-command installer for the Mushoku Tensei PC English patch (DMM client).

.DESCRIPTION
  - Downloads the latest EN patch (language bundle + inapp patch) from the
    rolling 'patch-latest' GitHub release and verifies size + md5.
  - Seeds the exact-size, CRC-forged language bundle into the Unity
    Addressables cache (__data). The catalog is left untouched; editing the
    catalog is what triggers the "Failed to acquire resources" integrity error.
  - Captures clean stock copies (inapp bundle + boot.config) the play wrapper
    needs so DMM's per-launch file check passes.

  Run this once. After that, play via Play-En.ps1.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -GameDir 'D:\Games\mushoku_coe_cl' -Force
#>
param(
    [string]$GameDir,
    [switch]$Force
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

# --- 2. download + verify the patch -----------------------------------------
Write-Host 'fetching latest patch from the patch-latest release ...'
$art = Get-PatchArtifacts -Force:$Force
$langBundle  = $art.Files.lang
$inappPatch  = $art.Files.inapp
Write-Host "  language bundle : $(Split-Path $langBundle -Leaf)  ($((Get-Item $langBundle).Length) B, md5 $((Get-Md5 $langBundle).Substring(0,8))...)"
Write-Host "  inapp patch     : $(Split-Path $inappPatch -Leaf)  ($((Get-Item $inappPatch).Length) B)"

# --- 3. stock backups (needed by Play-En.ps1) --------------------------------
# Keep clean stock copies so the wrapper can satisfy DMM's file check, then swap.
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
$res = Install-LanguageCache -LangBundlePath $langBundle
Write-Host "  cache : $($res.CacheDir)"
Write-Host "  __data md5 $($res.DataMd5.Substring(0,8))...  size-ok=$($res.SizeOk)"

if (-not $res.SizeOk) {
    Write-Host 'WARNING: seeded __data is not the expected 1,777,229 bytes.'
}

Write-Host ''
Write-Host 'Install complete. To play in English, run:'
Write-Host '  powershell -ExecutionPolicy Bypass -File Play-En.ps1'
Write-Host '(Play-En.ps1 keeps DMM''s file check happy and swaps the EN patch in at boot.)'

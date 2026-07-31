<#
.SYNOPSIS
  Launch the DMM PC client (mushoku_coe_cl) and play in English.

.DESCRIPTION
  DMM GAME PLAYER verifies every game file against the server manifest on each
  launch and repairs any mismatch, so a permanently-patched inapp bundle gets
  reverted. But the check runs before the exe spawns, and the game reads the
  bundle a moment into boot. This wrapper:

    1. restores the STOCK inapp bundle + boot.config  -> DMM file check passes
    2. (optional) asks DMM to launch the game
    3. when the exe spawns, swaps the EN inapp patch + logging boot.config in
    4. re-seeds the EN language bundle into the Unity cache
    5. when the game exits, restores STOCK for the next launch

  Run Install-EnPatch.ps1 once first.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Play-En.ps1            # arm + try to launch
  powershell -ExecutionPolicy Bypass -File Play-En.ps1 -NoLaunch  # arm only; click Play in DMM
#>
param(
    [string]$GameDir,
    [switch]$NoLaunch,
    [int]$WatchMinutes = 45
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'MT.EnPatch.psm1') -Force

# --- resolve paths (constants are global, exported by the module) --------------
$gameDir = Get-GameDir -Override $GameDir
if (-not $gameDir) { Write-Host 'Game not found. Run Install-EnPatch.ps1 first (or pass -GameDir).'; exit 1 }

$liveInapp  = Join-Path $gameDir $InappRelPath
$liveBoot   = Join-Path $gameDir $BootCfgRelPath
$stockInapp = Join-Path $PatchDataDir 'stock_inapp_assets_all.bundle'
$stockBoot  = Join-Path $PatchDataDir 'stock_boot.config'
$bootLog    = Join-Path $PatchDataDir 'boot_logging.config'
$inappPatch = Join-Path $PatchDataDir $InappFileName
$langBundle = Join-Path $PatchDataDir $LangFileName

$missing = @($stockInapp,$stockBoot,$bootLog,$inappPatch,$langBundle) | Where-Object { -not (Test-Path -LiteralPath $_) }
if ($missing) {
    Write-Host 'Missing patch files. Run Install-EnPatch.ps1 first:'
    $missing | ForEach-Object { Write-Host "  $_" }
    exit 1
}

# --- 1. stock in place so the DMM check passes clean ---------------------------
if ((Get-Md5 $liveInapp) -ne (Get-Md5 $stockInapp)) {
    Copy-Item -LiteralPath $stockInapp -Destination $liveInapp -Force
    Write-Host 'stock inapp restored (DMM file check will pass)'
} else {
    Write-Host 'stock inapp already in place'
}
Copy-Item -LiteralPath $stockBoot -Destination $liveBoot -Force

# --- 2. launch ------------------------------------------------------------------
if (-not $NoLaunch) {
    try { Start-Process 'dmmgameplayer://mushoku_coe_cl/'; Write-Host 'launch requested via DMM' }
    catch { Write-Host "auto-launch failed - click Play in DMM GAME PLAYER ($($_.Exception.Message))" }
} else {
    Write-Host 'watcher armed - click Play in DMM GAME PLAYER'
}

# --- 3. swap on spawn, restore on exit ------------------------------------------
$end = (Get-Date).AddMinutes($WatchMinutes)
$swapped = $false
while ((Get-Date) -lt $end) {
    $proc = Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and -not $swapped) {
        Start-Sleep -Milliseconds 400
        Copy-Item -LiteralPath $inappPatch -Destination $liveInapp -Force
        Copy-Item -LiteralPath $bootLog -Destination $liveBoot -Force
        Install-LanguageCache -LangBundlePath $langBundle | Out-Null
        $swapped = $true
        Write-Host "$(Get-Date -Format 'HH:mm:ss')  EN patch active (game pid $($proc.Id)); language cache seeded"
    }
    if ($swapped -and -not $proc) {
        Copy-Item -LiteralPath $stockInapp -Destination $liveInapp -Force
        Copy-Item -LiteralPath $stockBoot -Destination $liveBoot -Force
        Write-Host "$(Get-Date -Format 'HH:mm:ss')  game exited - stock restored"
        break
    }
    Start-Sleep -Milliseconds 200
}
if (-not $swapped) { Write-Host "timed out after $WatchMinutes min waiting for the game to start" }

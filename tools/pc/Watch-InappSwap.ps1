<#
.SYNOPSIS
  Keeps the English inapp_assets_all.bundle in place only while the game runs.

.DESCRIPTION
  The first load's title screen comes from the in-app bundle (StreamingAssets),
  which DMM GAME PLAYER verifies before it starts the game, so the English build
  cannot stay installed. Start this watcher, then click Play in DMM: it stages
  the English file next to the game folder, waits for the game process, swaps the
  two (a single File.Replace, before Unity opens the bundle) and swaps them back
  when the game exits. DMM always finds the stock file.

  The staged file deliberately does NOT live in StreamingAssets: it goes to
  <parent of the game folder>\mt-en-staging (same volume, so the swap stays an
  instant rename while DMM's own file check never sees it). If that folder can't
  be used the watcher falls back to inapp_assets_all.bundle.en next to the stock
  file, which is what the first release of this tool did.

  On start it repairs a swap left over from a crash. It does not swap when the
  installed bundle is not the stock file the English build was made from (game
  update: rebuild with tools\prefab-patch\build_inapp.py).

  English build: %LOCALAPPDATA%\MT-EN-Applier\pc\inapp_assets_all_en.bundle and
  its .json (stock_md5, md5, stock_size, crc), written by Install-EnPatch.ps1
  from the release's version.json.
  Log: %LOCALAPPDATA%\MT-EN-Applier\pc\inapp-swap.log

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Watch-InappSwap.ps1
  powershell -ExecutionPolicy Bypass -File Watch-InappSwap.ps1 -RestoreOnly
#>
param(
    [string]$GameDir,
    [string]$EnglishBundle,
    [string]$StageDir,
    [int]$TimeoutSec = 900,
    [switch]$RestoreOnly
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot      # absolute even when invoked as -File tools\pc\...
Import-Module (Join-Path $here 'MT.EnPatch.psm1') -Force

if (-not $EnglishBundle) { $EnglishBundle = Join-Path $PatchDataDir $InappFileName }
$metaPath = "$EnglishBundle.json"
$logPath = Join-Path $PatchDataDir 'inapp-swap.log'
New-Item -ItemType Directory -Force -Path $PatchDataDir | Out-Null

function Log([string]$m) {
    $line = '{0:HH:mm:ss.fff} {1}' -f (Get-Date), $m
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $line
}

$gameDir = Get-GameDir -Override $GameDir
if (-not $gameDir) { Write-Host 'Game folder not found; pass -GameDir.'; exit 1 }
$live = Join-Path $gameDir $InappRelPath
if (-not (Test-Path -LiteralPath $live)) { Write-Host "Not found: $live"; exit 1 }

# Same volume as the game, outside the game's own tree. File.Replace needs
# source, destination and backup on one volume to stay a rename.
function Resolve-StageDir {
    param([string]$Requested)
    $candidates = @()
    if ($Requested) { $candidates += $Requested }
    $candidates += (Join-Path (Split-Path $gameDir -Parent) 'mt-en-staging')
    foreach ($c in $candidates) {
        if ([IO.Path]::GetPathRoot($c) -ne [IO.Path]::GetPathRoot($live)) { continue }
        try { New-Item -ItemType Directory -Force -Path $c | Out-Null; return $c } catch { }
    }
    Log 'Staging folder unavailable; falling back to a file inside StreamingAssets.'
    return (Split-Path $live -Parent)
}
$stageDir  = Resolve-StageDir -Requested $StageDir
$staged    = Join-Path $stageDir ($InappFileName)
$stock     = Join-Path $stageDir 'inapp_assets_all.stock.bundle'
$legacy    = "$live.en"      # the first release staged in place; migrate on sight
$legacyStock = "$live.stock"

function Restore-Stock {
    $meta = $null
    if (Test-Path -LiteralPath $metaPath) {
        try { $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json } catch { }
    }
    foreach ($pair in @(@($stock, $staged), @($legacyStock, $legacy))) {
        $from, $to = $pair
        if (-not (Test-Path -LiteralPath $from)) { continue }
        try {
            if ((Test-Path -LiteralPath $live) -and $meta -and ((Get-Md5 $live) -eq $meta.md5)) {
                [IO.File]::Replace($from, $live, $null, $true)   # English in place: put stock back
            } elseif (-not (Test-Path -LiteralPath $live)) {
                [IO.File]::Move($from, $live)
            } else {
                Remove-Item -LiteralPath $from -Force            # both stock; drop the leftover
            }
            Log 'Restored the stock in-app bundle left over from a previous run.'
        } catch {
            Log ('Could not repair from ' + $from + ': ' + $_.Exception.Message)
        }
    }
    if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Force }
    if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Force }
}

Set-Content -LiteralPath $logPath -Value ('In-app swap watcher - ' + (Get-Date -Format o)) -Encoding UTF8
try {
    if (Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue) { Log 'Game already running; nothing to do.'; exit 0 }
    Restore-Stock
    if ($RestoreOnly) { exit 0 }

    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    if ((Get-Md5 $live) -ne $meta.stock_md5) {
        Log 'The installed in-app bundle is not the one the English build targets (game update?). Not swapping.'
        exit 2
    }
    if ((Test-Path -LiteralPath $staged) -and ((Get-Md5 $staged) -eq $meta.md5)) {
        Log 'English in-app bundle already staged.'
    } else {
        Copy-Item -LiteralPath $EnglishBundle -Destination $staged -Force
        if ((Get-Md5 $staged) -ne $meta.md5) { throw 'Staged English bundle failed its md5 check.' }
        Log 'English in-app bundle staged.'
    }
    Log 'Click Play in DMM GAME PLAYER.'

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $proc = $null
    while (-not $proc -and (Get-Date) -lt $deadline) {
        $proc = Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $proc) { Start-Sleep -Milliseconds 20 }
    }
    if (-not $proc) { Log "Game did not start within $TimeoutSec s; nothing swapped."; exit 3 }

    # One atomic-ish step: the English file takes the live path, the stock file
    # lands in the backup path, so there is no moment without a bundle there.
    [IO.File]::Replace($staged, $live, $stock, $true)
    Log "Game started (PID $($proc.Id)); English in-app bundle swapped in."

    $proc.WaitForExit()
    for ($i = 0; $i -lt 50; $i++) {   # the file handle can outlive the process briefly
        try { [IO.File]::Replace($stock, $live, $staged, $true); break }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (Test-Path -LiteralPath $stock) { throw "Could not put the stock bundle back (still at $stock)." }
    Log 'Game exited; stock in-app bundle restored.'
    exit 0
}
catch {
    Log ('ERROR: ' + $_.Exception.Message)
    try { Restore-Stock } catch { Log ('Restore failed: ' + $_.Exception.Message) }
    exit 1
}

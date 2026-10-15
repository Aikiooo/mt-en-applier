<#
.SYNOPSIS
  Keeps the English inapp_assets_all.bundle in place only while the game runs.

.DESCRIPTION
  The title screen of the first load comes from the in-app bundle
  (StreamingAssets), which DMM GAME PLAYER verifies before it starts the game,
  so the English build cannot stay installed. Start this watcher, then click
  Play in DMM: it stages the English file next to the stock one, waits for the
  game process, swaps the two by renaming (instant, before Unity opens the
  bundle) and swaps them back when the game exits. DMM always finds the stock
  file.

  On start it repairs a swap left over from a crash. It does not swap when the
  installed bundle is not the stock file the English build was made from (game
  update: rebuild with tools\prefab-patch\build_inapp.py).

  English build: %LOCALAPPDATA%\MT-EN-Applier\pc\inapp_assets_all_en.bundle
  and its .json (stock_md5, md5) written by build_inapp.py.
  Log: %LOCALAPPDATA%\MT-EN-Applier\pc\inapp-swap.log

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Watch-InappSwap.ps1
  powershell -ExecutionPolicy Bypass -File Watch-InappSwap.ps1 -RestoreOnly
#>
param(
    [string]$GameDir,
    [string]$EnglishBundle,
    [int]$TimeoutSec = 600,
    [switch]$RestoreOnly
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'MT.EnPatch.psm1') -Force

if (-not $EnglishBundle) { $EnglishBundle = Join-Path $PatchDataDir $InappFileName }
$logPath = Join-Path $PatchDataDir 'inapp-swap.log'
New-Item -ItemType Directory -Force -Path $PatchDataDir | Out-Null

function Log([string]$m) {
    $line = '{0:HH:mm:ss.fff} {1}' -f (Get-Date), $m
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $line
}

$gameDir = Get-GameDir -Override $GameDir
if (-not $gameDir) { Write-Host 'Game folder not found; pass -GameDir.'; exit 1 }
$live   = Join-Path $gameDir $InappRelPath
$staged = "$live.en"
$stock  = "$live.stock"

function Restore-Stock {
    if (Test-Path -LiteralPath $stock) {
        if (Test-Path -LiteralPath $live) { [IO.File]::Delete($live) }
        [IO.File]::Move($stock, $live)
        Log 'Restored the stock in-app bundle left over from a previous run.'
    }
    if (Test-Path -LiteralPath $staged) { [IO.File]::Delete($staged) }
}

Set-Content -LiteralPath $logPath -Value ('In-app swap watcher - ' + (Get-Date -Format o)) -Encoding UTF8
try {
    if (Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue) { Log 'Game already running; nothing to do.'; exit 0 }
    Restore-Stock
    if ($RestoreOnly) { exit 0 }

    $meta = Get-Content -LiteralPath "$EnglishBundle.json" -Raw | ConvertFrom-Json
    if ((Get-Md5 $live) -ne $meta.stock_md5) {
        Log 'The installed in-app bundle is not the one the English build targets (game update?). Not swapping.'
        exit 2
    }
    Copy-Item -LiteralPath $EnglishBundle -Destination $staged -Force
    if ((Get-Md5 $staged) -ne $meta.md5) { throw 'Staged English bundle failed its md5 check.' }
    Log 'English in-app bundle staged. Click Play in DMM GAME PLAYER.'

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $proc = $null
    while (-not $proc -and (Get-Date) -lt $deadline) {
        $proc = Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $proc) { Start-Sleep -Milliseconds 20 }
    }
    if (-not $proc) { [IO.File]::Delete($staged); Log 'Game did not start in time; nothing swapped.'; exit 3 }

    [IO.File]::Move($live, $stock)
    [IO.File]::Move($staged, $live)
    Log "Game started (PID $($proc.Id)); English in-app bundle swapped in."

    $proc.WaitForExit()
    for ($i = 0; $i -lt 50; $i++) {   # the file handle can outlive the process briefly
        try { [IO.File]::Move($live, $staged); break } catch { Start-Sleep -Milliseconds 200 }
    }
    [IO.File]::Move($stock, $live)
    [IO.File]::Delete($staged)
    Log 'Game exited; stock in-app bundle restored.'
    exit 0
}
catch {
    Log ('ERROR: ' + $_.Exception.Message)
    try { Restore-Stock } catch { Log ('Restore failed: ' + $_.Exception.Message) }
    exit 1
}

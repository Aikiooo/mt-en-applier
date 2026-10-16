<#
.SYNOPSIS
  Keeps the translated inapp_assets_all.bundle in place only while the game runs.

.DESCRIPTION
  The first load's title screen comes from the in-app bundle (StreamingAssets),
  which DMM GAME PLAYER verifies before it starts the game, so the translated build
  cannot stay installed. Start this watcher, then click Play in DMM: it stages
  the translated file next to the game folder, waits for the game process, swaps the
  two (a single File.Replace, before Unity opens the bundle) and swaps them back
  when the game exits. DMM always finds the stock file.

  The staged file deliberately does NOT live in StreamingAssets: it goes to
  <parent of the game folder>\mt-en-staging (same volume, so the swap stays an
  instant rename while DMM's own file check never sees it). If that folder can't
  be used the watcher falls back to inapp_assets_all_en.bundle next to the stock
  file, which is what the first release of this tool did.

  On start it repairs a swap left over from a crash, and it refuses to swap when
  the installed bundle is not the stock file the translated build was made from, or
  when that file changed while it was waiting (a game update in between). Only
  one watcher runs at a time per game folder.

  Translated build: %LOCALAPPDATA%\MT-EN-Applier\pc\inapp_assets_all_<code>.bundle
  (inapp_assets_all_en.bundle for English) and its .json (stock_md5, md5,
  stock_size, crc), written by Install-EnPatch.ps1 from the release's
  version.json. Play-in-<Language>.cmd passes it with -EnglishBundle (the name
  predates the other languages); without it, the one the installer set up last
  is used.
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

# The installer keeps one language's build at a time; the newest one with its
# metadata beside it is the one it set up last.
function Get-PatchedBuilds {
    @(Get-ChildItem -LiteralPath $PatchDataDir -Filter 'inapp_assets_all_*.bundle' -File -ErrorAction SilentlyContinue |
      Where-Object { Test-Path -LiteralPath "$($_.FullName).json" } | Sort-Object LastWriteTimeUtc -Descending)
}
if (-not $EnglishBundle) {
    $newest = Get-PatchedBuilds | Select-Object -First 1
    $EnglishBundle = if ($newest) { $newest.FullName } else { Join-Path $PatchDataDir $InappFileName }
}
$metaPath = "$EnglishBundle.json"
$logPath = Join-Path $PatchDataDir 'inapp-swap.log'
$settingsPath = Join-Path $PatchDataDir 'settings.json'
New-Item -ItemType Directory -Force -Path $PatchDataDir | Out-Null

function Log([string]$m) {
    $line = '{0:HH:mm:ss.fff} {1}' -f (Get-Date), $m
    # Never let a log failure take the watcher down: it matters most exactly
    # when something else has gone wrong.
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    Write-Host $line
}

$gameDir = Get-GameDir -Override $GameDir
if (-not $gameDir) {
    # The installer records the folder it resolved, for players whose DMM config
    # does not name the game or who had to pass -GameDir themselves.
    try {
        if (Test-Path -LiteralPath $settingsPath) {
            $gameDir = (Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json).game_dir
        }
    } catch { }
}
if (-not $gameDir) { Write-Host 'Game folder not found; pass -GameDir.'; exit 1 }
$live = Join-Path $gameDir $InappRelPath
if (-not (Test-Path -LiteralPath $live)) { Write-Host "Not found: $live"; exit 1 }

# One watcher per game folder: two of them fight over the same files, and the
# loser can put the stock bundle back while the game is starting. The path is
# normalised first so "-GameDir D:\x" and the path from DMM's config agree.
$key = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash(
    [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($live).ToLowerInvariant()))).Replace('-', '')
$mutex = New-Object System.Threading.Mutex($false, "Local\mt-en-inapp-$key")
try { $mine = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $mine = $true }
if (-not $mine) {
    Write-Host 'Another MT-EN in-app watcher is already running for this game; nothing to do.'
    exit 0
}

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
$staged    = Join-Path $stageDir (Split-Path $EnglishBundle -Leaf)
$stock     = Join-Path $stageDir 'inapp_assets_all.stock.bundle'
$legacy    = "$live.en"      # the first release staged in place; migrate on sight
$legacyStock = "$live.stock"

# Put back whatever a previous run left behind. The stock copy is only ever
# deleted once the installed bundle is provably the stock one: it can be the
# only copy left.
function Restore-Stock {
    $meta = $null
    if (Test-Path -LiteralPath $metaPath) {
        try { $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json } catch { }
    }
    if (-not $meta) {
        Log 'No metadata beside the translated bundle; leaving staged files alone.'
        return
    }
    # A crash during a session in another language leaves that build live: it is
    # still ours, so it is recognised by any build's metadata kept here.
    $ours = @($meta.md5)
    foreach ($b in Get-PatchedBuilds) {
        try { $ours += (Get-Content -LiteralPath "$($b.FullName).json" -Raw | ConvertFrom-Json).md5 } catch { }
    }
    foreach ($pair in @(@($stock, $staged), @($legacyStock, $legacy))) {
        $from = $pair[0]
        if (-not (Test-Path -LiteralPath $from)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $live)) {
                # File.Replace can die between its two steps: the stock copy is
                # the only one left, so it goes back.
                [IO.File]::Move($from, $live)
                Log 'Put the stock in-app bundle back (the game folder had none).'
            } elseif ($ours -contains (Get-Md5 $live)) {
                # Ours is live: park it (reused next session) and restore stock.
                [IO.File]::Replace($from, $live, $staged, $true)
                Log 'Restored the stock in-app bundle left over from a previous run.'
            } elseif ((Get-Md5 $live) -eq $meta.stock_md5) {
                Remove-Item -LiteralPath $from -Force             # both stock; drop the copy
            } else {
                Log ('Leaving ' + $from + ' alone: the installed bundle is neither the stock nor a translated build.')
            }
        } catch {
            Log ('Could not repair from ' + $from + ': ' + $_.Exception.Message)
        }
    }
    if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Force }
}

Log ('watcher start - live ' + $live + ' ; staging ' + $stageDir)
try {
    if (Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue) { Log 'Game already running; nothing to do.'; exit 0 }
    Restore-Stock
    if ($RestoreOnly) { exit 0 }

    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    if ((Get-Md5 $live) -ne $meta.stock_md5) {
        Log 'The installed in-app bundle is not the one the translated build targets (game update?). Not swapping.'
        exit 2
    }
    $liveStamp = (Get-Item -LiteralPath $live).LastWriteTimeUtc
    $liveSize  = (Get-Item -LiteralPath $live).Length

    if ((Test-Path -LiteralPath $staged) -and ((Get-Md5 $staged) -eq $meta.md5)) {
        Log 'Translated in-app bundle already staged.'
    } else {
        Copy-Item -LiteralPath $EnglishBundle -Destination $staged -Force
        if ((Get-Md5 $staged) -ne $meta.md5) { throw 'Staged translated bundle failed its md5 check.' }
        Log ('Translated in-app bundle staged (' + (Split-Path $EnglishBundle -Leaf) + ').')
    }
    Log 'Click Play in DMM GAME PLAYER.'

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $proc = $null
    while (-not $proc -and (Get-Date) -lt $deadline) {
        $proc = Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $proc) { Start-Sleep -Milliseconds 20 }
    }
    if (-not $proc) { Log "Game did not start within $TimeoutSec s; nothing swapped."; exit 3 }

    # A game update while we waited replaces the stock file, and the translated
    # build's CRC was forged for the one it was made from.
    $now = Get-Item -LiteralPath $live
    if ($now.Length -ne $liveSize -or $now.LastWriteTimeUtc -ne $liveStamp) {
        Log 'The stock in-app bundle changed while waiting (game update?); not swapping.'
        exit 2
    }

    # One atomic-ish step: the translated file takes the live path, the stock file
    # lands in the backup path, so there is no moment without a bundle there.
    [IO.File]::Replace($staged, $live, $stock, $true)
    Log "Game started (PID $($proc.Id)); translated in-app bundle swapped in."

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
    if (Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue) {
        # Leave the files alone while the game runs; the next run repairs them.
        Log 'The game is still running; leaving the bundles as they are (the next run repairs them).'
    } else {
        try { Restore-Stock } catch { Log ('Restore failed: ' + $_.Exception.Message) }
    }
    exit 1
}

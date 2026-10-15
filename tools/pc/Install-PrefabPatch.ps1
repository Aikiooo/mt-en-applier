<#
.SYNOPSIS
  Installs (or removes) the English UI-prefab patch in the PC game's Addressables cache.

.DESCRIPTION
  Copies the bundles built by tools\prefab-patch\build_prefab_patch.py over the
  matching cached bundles (...\LocalLow\Unity\GREE Entertainment_*\<name>\<hash>\__data).
  A bundle is replaced only while it is still the exact file the patch was built
  from (md5 in manifest.json); the original is backed up first. Bundles the game
  has updated since are skipped and listed (rebuild the patch for them).

  Only the Unity cache is touched, so DMM's file check is unaffected (same place
  as the language bundle). The game must be closed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-PrefabPatch.ps1 -PatchDir ..\..\build\prefab-patch
  powershell -ExecutionPolicy Bypass -File Install-PrefabPatch.ps1 -Check
  powershell -ExecutionPolicy Bypass -File Install-PrefabPatch.ps1 -Restore
#>
param(
    # Folder holding manifest.json and the <name>\<hash>\__data tree.
    [string]$PatchDir,
    # Put the backed-up Japanese bundles back.
    [switch]$Restore,
    # Report only, change nothing.
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot      # absolute even when invoked as -File tools\pc\...
Import-Module (Join-Path $here 'MT.EnPatch.psm1') -Force

if (-not $PatchDir) { $PatchDir = Join-Path $PatchDataDir 'prefab-patch' }
$backupDir = Join-Path $PatchDataDir 'prefab-backup'
$manifestPath = Join-Path $PatchDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Host "No prefab patch at $PatchDir (manifest.json missing)."; exit 1 }
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue) { Write-Host 'Close the game first.'; exit 1 }
$cache = Get-UnityCachePublisherDir
if (-not $cache) { Write-Host 'Unity cache not found. Launch the game once to the title screen.'; exit 1 }

$n = [ordered]@{ installed = 0; already = 0; restored = 0; skipped = 0; missing = 0; nobackup = 0 }
$skipped = @()
$notBackedUp = @()
foreach ($e in $manifest) {
    $rel    = $e.rel -replace '/', '\'
    $target = Join-Path $cache $rel
    $backup = Join-Path $backupDir $rel
    if (-not (Test-Path -LiteralPath $target)) { $n.missing++; continue }
    $cur = Get-Md5 $target

    if ($Restore) {
        if ($cur -ne $e.out_md5) {
            # Ours is gone: either the game put its own copy back, or an update
            # replaced the bundle (that one is no longer ours to restore).
            if ($cur -eq $e.src_md5) { $n.already++ } else { $n.skipped++; $skipped += $e.rel }
            continue
        }
        if (-not (Test-Path -LiteralPath $backup)) { $n.nobackup++; $notBackedUp += $e.rel; continue }
        if (-not $Check) {
            Copy-Item -LiteralPath $backup -Destination $target -Force
            if ((Get-Md5 $target) -ne $e.src_md5) { throw "Restore verification failed: $target" }
        }
        $n.restored++
        continue
    }
    if ($cur -eq $e.out_md5) { $n.already++; continue }
    if ($cur -ne $e.src_md5) { $n.skipped++; $skipped += $e.rel; continue }
    if (-not $Check) {
        if (-not (Test-Path -LiteralPath $backup)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
            Copy-Item -LiteralPath $target -Destination $backup
        }
        Copy-Item -LiteralPath (Join-Path $PatchDir $rel) -Destination $target -Force
        if ((Get-Md5 $target) -ne $e.out_md5) { throw "Copy verification failed: $target" }
    }
    $n.installed++
}

$mode = if ($Restore) { 'restore' } else { 'install' }
if ($Check) { $mode += ' (check only)' }
Write-Host "Prefab patch $mode : $(@($manifest).Count) bundles"
$n.GetEnumerator() | ForEach-Object { Write-Host ('  {0,-10} {1}' -f $_.Key, $_.Value) }
if ($skipped) {
    Write-Host 'Changed by a game update since the patch was built (rebuild for these):'
    $skipped | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
}
if ($notBackedUp) {
    Write-Host 'Patched by us but with no backup saved (cannot restore these by hand):'
    $notBackedUp | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
}

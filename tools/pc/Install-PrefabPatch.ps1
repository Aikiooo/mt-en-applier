<#
.SYNOPSIS
  Installs (or removes) the English UI-prefab patch in the PC game's Addressables cache.

.DESCRIPTION
  Copies the bundles built by tools\prefab-patch\build_prefab_patch.py over the
  matching cached bundles (...\LocalLow\Unity\GREE Entertainment_*\<name>\<hash>\__data).
  A bundle is replaced only while it is still the exact file the patch was built
  from (md5 in manifest.json); the original is backed up first. Bundles the game
  has updated since are skipped and listed (rebuild the patch for them).

  A bundle that carries our backup is recognised as ours even when it holds an
  older English build (a republished translation keeps the same source md5), so
  it is replaced rather than skipped, and -Restore can still put the Japanese
  file back.

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
# Throwing, not exiting: callers (Install-EnPatch.ps1) invoke this in-process and
# can catch it, which "exit 1" would not give them.
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No prefab patch at $PatchDir (manifest.json missing)." }
# No @() around the pipeline: Windows PowerShell 5.1 does not enumerate a JSON
# array out of ConvertFrom-Json, so @() would wrap it into a single item. A
# one-entry manifest parses as a lone object, hence the @() on the variable.
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest = @($manifest)
if ($manifest.Count -eq 0) { throw 'Prefab manifest is empty.' }

if (Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue) { throw 'Close the game first.' }
$cache = Get-UnityCachePublisherDir
if (-not $cache) { throw 'Unity cache not found. Launch the game once to the title screen.' }

$n = [ordered]@{ installed = 0; already = 0; restored = 0; skipped = 0; missing = 0; nobackup = 0 }
$skipped = @()
$notBackedUp = @()
foreach ($e in $manifest) {
    $rel    = $e.rel -replace '/', '\'
    $target = Join-Path $cache $rel
    $backup = Join-Path $backupDir $rel
    $cur = if (Test-Path -LiteralPath $target) { Get-Md5 $target } else { $null }
    # Our own previous write: the backup holds the stock file this build wants.
    $mine = (Test-Path -LiteralPath $backup) -and ((Get-Md5 $backup) -eq $e.src_md5)

    if ($Restore) {
        if ($cur -eq $e.src_md5) { $n.already++; continue }               # already Japanese
        if ($cur -eq $e.out_md5 -or $mine) {
            if (-not $mine) { $n.nobackup++; $notBackedUp += $e.rel; continue }
            if (-not $Check) {
                Copy-Item -LiteralPath $backup -Destination $target -Force
                if ((Get-Md5 $target) -ne $e.src_md5) { throw "Restore verification failed: $target" }
            }
            $n.restored++
            continue
        }
        if ($null -eq $cur) { $n.missing++; continue }
        $n.skipped++; $skipped += $e.rel
        continue
    }

    if ($null -eq $cur) { $n.missing++; continue }
    if ($cur -eq $e.out_md5) { $n.already++; continue }
    if ($cur -ne $e.src_md5 -and -not $mine) { $n.skipped++; $skipped += $e.rel; continue }
    if (-not $Check) {
        if (-not $mine) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
            Copy-Item -LiteralPath $target -Destination $backup
        }
        # Write beside the target and swap it in: a copy interrupted halfway
        # would otherwise leave a bundle that is neither file and cannot be
        # recognised by a later restore. (Move-Item, not File.Replace: this
        # would need a backup path, and $null reaches .NET as an empty string.)
        $tmp = "$target.mtentmp"
        Copy-Item -LiteralPath (Join-Path $PatchDir $rel) -Destination $tmp -Force
        if ((Get-Md5 $tmp) -ne $e.out_md5) { Remove-Item -LiteralPath $tmp -Force; throw "Copy verification failed: $target" }
        Move-Item -LiteralPath $tmp -Destination $target -Force
        if ((Get-Md5 $target) -ne $e.out_md5) { throw "Install verification failed: $target" }
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
if (-not $Restore -and $n.missing) {
    Write-Host "$($n.missing) of $(@($manifest).Count) bundles are not in the Unity cache."
    Write-Host 'Launch the game once to the title screen so it downloads them, close it, then re-run this installer.'
}

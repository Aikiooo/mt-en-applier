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
  it is replaced rather than skipped.

  -Restore walks the backup folder, not the manifest: the originals are what has
  to go back, and that works even when the manifest is gone, older, or missing a
  bundle the current build no longer contains. A bundle that cannot be restored
  is counted and the rest go ahead.

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
    [switch]$Check,
    # Install the text/prefab side only: bundles that carry nothing but images
    # are left alone (the ones carrying text are installed whole, since one file
    # holds both).
    [switch]$SkipTextures
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot      # absolute even when invoked as -File tools\pc\...
Import-Module (Join-Path $here 'MT.EnPatch.psm1') -Force

if (-not $PatchDir) { $PatchDir = Join-Path $PatchDataDir 'prefab-patch' }
$backupDir = Join-Path $PatchDataDir 'prefab-backup'
$manifestPath = Join-Path $PatchDir 'manifest.json'
# Throwing, not exiting: Install-EnPatch.ps1 invokes this in-process and catches
# it, which "exit 1" would not give it.
if (Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue) { throw 'Close the game first.' }
$cache = Get-UnityCachePublisherDir
if (-not $cache) { throw 'Unity cache not found. Launch the game once to the title screen.' }

$n = [ordered]@{ installed = 0; already = 0; restored = 0; failed = 0; skipped = 0; missing = 0; nobackup = 0; images_skipped = 0 }
$skipped = @()
$notBackedUp = @()

if ($Restore) {
    # The backups are the truth here: they mirror the cache layout, and each one
    # is the stock file for the bundle at the same relative path.
    $backups = @(Get-ChildItem -LiteralPath $backupDir -Recurse -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -eq '__data' })
    if (-not $backups) {
        Write-Host "Nothing to restore: no backups in $backupDir."
        return [pscustomobject]@{ mode = 'restore'; restored = 0; failed = 0; already = 0 }
    }
    foreach ($b in $backups) {
        $rel = $b.FullName.Substring($backupDir.Length).TrimStart('\', '/')
        $target = Join-Path $cache $rel
        $want = Get-Md5 $b.FullName
        if ((Test-Path -LiteralPath $target) -and ((Get-Md5 $target) -eq $want)) { $n.already++; continue }
        if ($Check) { $n.restored++; continue }
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $b.FullName -Destination $target -Force
            if ((Get-Md5 $target) -ne $want) { throw "copy does not verify" }
            $n.restored++
        } catch {
            $n.failed++
            Write-Host "  could not restore $rel : $($_.Exception.Message)"
        }
    }
    $n.GetEnumerator() | ForEach-Object { Write-Host ('  {0,-10} {1}' -f $_.Key, $_.Value) }
    if ($n.failed) { Write-Host "$($n.failed) bundles could not be restored; the backups are kept, so re-running -Restore retries them." }
    return [pscustomobject]@{ mode = 'restore'; restored = $n.restored; failed = $n.failed; already = $n.already }
}

if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No prefab patch at $PatchDir (manifest.json missing)." }
# No @() around the pipeline: Windows PowerShell 5.1 does not enumerate a JSON
# array out of ConvertFrom-Json, so @() would wrap it into a single item. A
# one-entry manifest parses as a lone object, hence the @() on the variable.
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest = @($manifest)
if ($manifest.Count -eq 0) { throw 'Prefab manifest is empty.' }

foreach ($e in $manifest) {
    $rel    = $e.rel -replace '/', '\'
    $target = Join-Path $cache $rel
    $backup = Join-Path $backupDir $rel
    $imageOnly = $SkipTextures -and (Get-Prop $e 'textures') -and -not (Get-Prop $e 'changed')
    if ($imageOnly) { $n.images_skipped++; continue }
    if (-not (Test-Path -LiteralPath $target)) { $n.missing++; continue }
    $cur = Get-Md5 $target
    # Our own previous write: the backup holds the stock file this build wants.
    $mine = (Test-Path -LiteralPath $backup) -and ((Get-Md5 $backup) -eq $e.src_md5)

    if ($cur -eq $e.out_md5) { $n.already++; continue }
    if ($cur -ne $e.src_md5 -and -not $mine) { $n.skipped++; $skipped += $e.rel; continue }
    if (-not $Check) {
        if (-not $mine) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
            Copy-Item -LiteralPath $target -Destination $backup
        }
        # Write beside the target and swap it in: a copy interrupted halfway
        # would otherwise leave a bundle that is neither file and cannot be
        # recognised by a later restore. (File.Replace needs a backup path, and
        # $null reaches .NET as an empty string, which it rejects.)
        $tmp = "$target.mtentmp"
        Copy-Item -LiteralPath (Join-Path $PatchDir $rel) -Destination $tmp -Force
        if ((Get-Md5 $tmp) -ne $e.out_md5) { Remove-Item -LiteralPath $tmp -Force; throw "Copy verification failed: $target" }
        [IO.File]::Replace($tmp, $target, "$tmp.bak", $true)
        Remove-Item -LiteralPath "$tmp.bak" -Force -ErrorAction SilentlyContinue
        if ((Get-Md5 $target) -ne $e.out_md5) { throw "Install verification failed: $target" }
    }
    $n.installed++
}

$mode = if ($Check) { 'install (check only)' } else { 'install' }
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
if ($n.missing) {
    Write-Host "$($n.missing) of $(@($manifest).Count) bundles are not in the Unity cache."
    Write-Host 'Launch the game once to the title screen so it downloads them, close it, then re-run this installer.'
}
return [pscustomobject]@{ mode = $mode; installed = $n.installed; already = $n.already; skipped = $n.skipped
                          missing = $n.missing; failed = 0; images_skipped = $n.images_skipped }

<#
.SYNOPSIS
  Maintainer: build the batteries-included PC user zip for the Releases tab.

.DESCRIPTION
  Users should never have to clone the repo or open a terminal. This packages
  the tools/pc folder into a single zip that someone downloads, extracts, and
  uses via two double-click files (Install-EnPatch.bat, then Play-En.bat).

  The zip contains ONLY the user-facing files:
    Install-EnPatch.bat / .ps1   - double-click installer
    Play-En.bat / .ps1           - double-click play launcher
    MT.EnPatch.psm1              - shared helpers the two scripts import
    START-HERE.txt               - the 3-step plain-language guide
    README.md                    - the full guide

  Maintainer scripts (this folder) are deliberately excluded.

  The zip does NOT contain the translated bundles themselves - the installer
  downloads those from the rolling 'patch-latest' release at install time, so
  this zip stays tiny and never goes stale.

.EXAMPLE
  # build the zip (review it, then attach it to a GitHub release)
  powershell -File maintainer\Build-PcZip.ps1

.EXAMPLE
  # build and immediately create a GitHub release with the zip attached
  powershell -File maintainer\Build-PcZip.ps1 -Tag pc-v1 -Publish
#>
param(
    [string]$OutDir = (Join-Path $env:TEMP 'mt-pc-zip'),
    [string]$ZipName = 'MushokuTensei-PC-English-Patch.zip',
    [string]$Repo = 'Aikiooo/mt-en-applier',
    # If set with -Publish, the release is created/updated under this tag.
    [string]$Tag = 'pc-v1',
    [string]$ReleaseTitle = 'PC English Patch (DMM)',
    [switch]$Publish
)

$ErrorActionPreference = 'Stop'
$pcDir   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)  # tools\pc
$staging = Join-Path $OutDir 'staging'
$zipPath = Join-Path $OutDir $ZipName

$userFiles = @(
    'Install-EnPatch.bat',
    'Install-EnPatch.ps1',
    'Play-En.bat',
    'Play-En.ps1',
    'MT.EnPatch.psm1',
    'START-HERE.txt',
    'README.md'
)

# --- stage ---------------------------------------------------------------------
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
foreach ($f in $userFiles) {
    $src = Join-Path $pcDir $f
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "ERROR: expected user file missing: $src"; exit 1 }
    Copy-Item -LiteralPath $src -Destination (Join-Path $staging $f) -Force
}

# --- zip -----------------------------------------------------------------------
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal

Write-Host "built $zipPath ($((Get-Item $zipPath).Length) B) containing:"
Get-ChildItem -LiteralPath $staging | ForEach-Object { Write-Host ("  {0}" -f $_.Name) }

# --- optional publish ----------------------------------------------------------
if ($Publish) {
    $exists = $false
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # don't let gh's stderr abort the script
    gh release view $Tag --repo $Repo 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $exists = $true }
    $ErrorActionPreference = $prevEAP

    $notes = @'
**One download, two double-clicks - no terminal, no repo clone.**

1. Download and extract the zip below.
2. Double-click **`Install-EnPatch.bat`** (once).
3. Double-click **`Play-En.bat`** every time you play, then click Play in DMM GAME PLAYER.

Open **`START-HERE.txt`** in the zip for the plain-language walkthrough.

The translated data itself downloads automatically at install time from the rolling
[`patch-latest`](https://github.com/Aikiooo/mt-en-applier/releases/tag/patch-latest)
release, so this zip stays current.
'@

    if ($exists) {
        Write-Host "release '$Tag' exists - uploading (clobber) ..."
        gh release upload $Tag $zipPath --repo $Repo --clobber
    } else {
        Write-Host "creating release '$Tag' ($ReleaseTitle) ..."
        gh release create $Tag $zipPath --repo $Repo --title $ReleaseTitle --notes $notes
    }
    Write-Host 'published.'
} else {
    Write-Host ''
    Write-Host 'Review the zip, then publish with:'
    Write-Host "  powershell -File maintainer\Build-PcZip.ps1 -Tag $Tag -Publish"
    Write-Host '(or attach it to a release manually on GitHub)'
}

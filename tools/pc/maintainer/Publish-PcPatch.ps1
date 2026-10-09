<#
.SYNOPSIS
  Maintainer: stage the PC patch artifacts and (optionally) publish them to the
  rolling 'patch-latest' release alongside the Android assets.

.DESCRIPTION
  The Android side of patch-latest is produced by update_translation.py. This
  script adds the PC build without disturbing it:

    - copies the proven PC bundles into a staging dir under their release names,
    - merges a nested "pc" block into version.json (leaves every existing
      Android key untouched, since the Android app parses them),
    - with -Publish, uploads the PC bundles + updated version.json via gh.

  PC source bundles are NOT committed to the repo (too large); keep them in the
  workspace pc_client folder. Pass -SourceDir if they live elsewhere.

.EXAMPLE
  # stage only (review the output first)
  powershell -File maintainer\Publish-PcPatch.ps1

  # stage + upload to patch-latest
  powershell -File maintainer\Publish-PcPatch.ps1 -Publish
#>
param(
    [string]$SourceDir = 'D:\grok\Mushoku Tensei\pc_client',
    [string]$LangBundleName   = 'language-ja_en_exact1898964.bundle',
    [string]$InappPatchName   = 'inapp_assets_all_en.bundle',
    # Unity cache asset-hash subfolder for the language bundle (the folder the
    # game looks in: …\GREE Entertainment_*\<guid>\<hash>\__data). MUST match the
    # bundle's current asset hash or fresh PC installs seed the wrong folder.
    [string]$LangBundleHash = '515508ac386204f43f28aea20ba4e470',
    [string]$OutDir = (Join-Path $env:TEMP 'mt-pc-patch-release'),
    [switch]$Publish,
    [string]$Repo = 'Aikiooo/mt-en-applier',
    [string]$Release = 'patch-latest'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\MT.EnPatch.psm1') -Force

$langSrc  = Join-Path $SourceDir $LangBundleName
$inappSrc = Join-Path $SourceDir $InappPatchName
foreach ($f in @($langSrc, $inappSrc)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "ERROR: missing PC artifact: $f"; exit 1 }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$langDst  = Join-Path $OutDir $LangFileName
$inappDst = Join-Path $OutDir $InappFileName
Copy-Item -LiteralPath $langSrc  -Destination $langDst  -Force
Copy-Item -LiteralPath $inappSrc -Destination $inappDst -Force

if ($LangBundleHash -notmatch '^[0-9a-f]{32}$') {
    Write-Host "ERROR: -LangBundleHash must be the 32-hex asset hash, got '$LangBundleHash'"; exit 1
}

$pcBlock = [ordered]@{
    language_ja_en = [ordered]@{
        size = (Get-Item $langDst).Length
        md5  = Get-Md5 $langDst
        hash = $LangBundleHash
    }
    inapp_assets_all_en = [ordered]@{
        size = (Get-Item $inappDst).Length
        md5  = Get-Md5 $inappDst
    }
}

# Merge into the live version.json, preserving the Android keys.
$versionPath = Join-Path $OutDir $VersionFile
Invoke-WebRequest -UseBasicParsing -Uri "$($ReleaseBase)/$($VersionFile)" -OutFile $versionPath
$version = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
$version | Add-Member -NotePropertyName pc -NotePropertyValue $pcBlock -Force
# Write BOM-free UTF-8: Set-Content -Encoding utf8 adds a BOM on Windows
# PowerShell 5.1, which breaks the Android app's minimal JSON parser.
[System.IO.File]::WriteAllText($versionPath,
    ($version | ConvertTo-Json -Depth 6),
    (New-Object System.Text.UTF8Encoding($false)))

Write-Host "staged in $OutDir :"
Get-ChildItem -LiteralPath $OutDir | ForEach-Object { Write-Host ("  {0}  {1} B" -f $_.Name, $_.Length) }
Write-Host "  pc.language_ja_en : $($pcBlock.language_ja_en.size) B  md5 $($pcBlock.language_ja_en.md5)"
Write-Host "  pc.inapp          : $($pcBlock.inapp_assets_all_en.size) B  md5 $($pcBlock.inapp_assets_all_en.md5)"

if ($Publish) {
    Write-Host "uploading to $Repo@$Release ..."
    gh release upload $Release $langDst $inappDst $versionPath --repo $Repo --clobber
    Write-Host 'done.'
} else {
    Write-Host ''
    Write-Host 'Review the staged files, then publish with:'
    Write-Host "  powershell -File maintainer\Publish-PcPatch.ps1 -Publish"
}

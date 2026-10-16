<#
.SYNOPSIS
  Maintainer: stage the PC patch artifacts and (optionally) publish them to the
  rolling 'patch-latest' release alongside the Android assets.

.DESCRIPTION
  The Android side of patch-latest is produced by update_translation.py. This
  script adds the PC build without disturbing it:

    - copies the proven PC bundles into a staging dir under their release names,
    - stages the English in-app bundle with the stock_md5/crc metadata the swap
      watcher needs (from the .json build_inapp.py writes next to it),
    - zips the English UI prefabs (build\prefab-patch, no compression: the
      bundles are already LZ4HC) as prefab-patch.zip,
    - merges a nested "pc" block into version.json (leaves every existing
      Android key untouched, since the Android app parses them),
    - with -Publish, uploads the artifacts first and version.json last, so an
      installer never sees a version.json pointing at files that aren't there.

  It refuses to stage a prefab zip whose source bundles no longer match the
  local Unity cache: that means the cache was rebuilt by a game update and the
  zip was built from a stock cache that has since moved on. Re-run
  Install-PrefabPatch.ps1 -Restore and rebuild first (-SkipCacheCheck to force).

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
    # English in-app bundle + the .json build_inapp.py writes next to it.
    [string]$InappBuild       = '',
    # English UI prefab tree (manifest.json + <name>\<hash>\__data).
    [string]$PrefabDir        = '',
    # Unity cache asset-hash subfolder for the language bundle (the folder the
    # game looks in: …\GREE Entertainment_*\<guid>\<hash>\__data). MUST match the
    # bundle's current asset hash or fresh PC installs seed the wrong folder.
    [string]$LangBundleHash = '515508ac386204f43f28aea20ba4e470',
    [string]$OutDir = (Join-Path $env:TEMP 'mt-pc-patch-release'),
    # Skips BOTH checks that need the local cache: the prefab source md5s and the
    # language build the cache is running.
    [switch]$SkipCacheCheck,
    [switch]$Publish,
    [string]$Repo = 'Aikiooo/mt-en-applier',
    [string]$Release = 'patch-latest'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot      # absolute even when invoked as -File tools\pc\...
$repoRoot = (Resolve-Path (Join-Path $here '..\..\..')).Path
# The module exports variables named Repo and Release, which would overwrite this
# script's own -Repo/-Release parameters on import, so they are read first.
$ghRepo = $Repo
$ghRelease = $Release
Import-Module (Join-Path $here '..\MT.EnPatch.psm1') -Force
. (Join-Path $here 'PrefabZips.ps1')

if (-not $InappBuild) { $InappBuild = Join-Path $repoRoot 'build\inapp_assets_all_en.bundle' }
if (-not $PrefabDir)  { $PrefabDir  = Join-Path $repoRoot 'build\prefab-patch' }
$inappMeta = "$InappBuild.json"

$langSrc  = Join-Path $SourceDir $LangBundleName
foreach ($f in @($langSrc, $InappBuild, $inappMeta)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "ERROR: missing PC artifact: $f"
        if ($f -eq $InappBuild -or $f -eq $inappMeta) {
            Write-Host 'Build it with: py -I -X utf8 tools\prefab-patch\build_inapp.py --language-bundle <bundle> --translation-cache translation_cache.json'
        }
        exit 1
    }
}
if ($LangBundleHash -notmatch '^[0-9a-f]{32}$') {
    Write-Host "ERROR: -LangBundleHash must be the 32-hex asset hash, got '$LangBundleHash'"; exit 1
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$langDst  = Join-Path $OutDir $LangFileName
$inappDst = Join-Path $OutDir $InappFileName
Copy-Item -LiteralPath $langSrc   -Destination $langDst   -Force
Copy-Item -LiteralPath $InappBuild -Destination $inappDst -Force

$meta = Get-Content -LiteralPath $inappMeta -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $meta.stock_md5) {
    Write-Host "ERROR: $inappMeta has no stock_md5 - Watch-InappSwap.ps1 cannot verify which file to swap. Rebuild the bundle."
    exit 1
}

$pcBlock = [ordered]@{
    language_ja_en = [ordered]@{
        size = (Get-Item $langDst).Length
        md5  = Get-Md5 $langDst
        hash = $LangBundleHash
    }
    inapp_assets_all_en = [ordered]@{
        size       = (Get-Item $inappDst).Length
        md5        = Get-Md5 $inappDst
        stock_md5  = $meta.stock_md5
        stock_size = $meta.stock_size
        crc        = $meta.crc
    }
}

# --- English UI prefabs (optional: only once they have been built) ------------
$prefabZip = Join-Path $OutDir $PrefabZipName
$manifestPath = Join-Path $PrefabDir 'manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    # No @() around the pipeline: Windows PowerShell 5.1 does not enumerate a
    # JSON array out of ConvertFrom-Json, so @() would wrap it into a 1-element
    # array whose single item is the list. A one-entry manifest parses as a lone
    # object, hence the @() on the variable.
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest = @($manifest)
    if ($manifest.Count -eq 0) { Write-Host 'ERROR: prefab manifest is empty.'; exit 1 }

    if (-not $SkipCacheCheck) {
        $cache = Get-UnityCachePublisherDir
        if (-not $cache) { Write-Host 'ERROR: Unity cache not found; cannot verify the prefab build. Use -SkipCacheCheck to force.'; exit 1 }
        $stale = @()
        foreach ($e in $manifest) {
            $target = Join-Path $cache ($e.rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $target)) { $stale += "$($e.rel) (gone)"; continue }
            if ((Get-Md5 $target) -ne $e.src_md5) { $stale += "$($e.rel) (changed)" }
        }
        if ($stale) {
            Write-Host "ERROR: $($stale.Count) of $($manifest.Count) cached bundles are not the stock files this build was made from."
            Write-Host 'The game updated (or the patch is still installed). Repair the game files / run'
            Write-Host 'Install-PrefabPatch.ps1 -Restore, then rebuild with build_prefab_patch.py.'
            $stale | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
            exit 1
        }
        # The game build this patch belongs to is the language folder the game is
        # using here, not the parameter's default: a mismatch means this machine
        # is on another build than the one being published.
        $langDir = Get-LangCacheDir
        if ($langDir) {
            $cacheHash = Split-Path $langDir -Leaf
            if ($cacheHash -ne $LangBundleHash) {
                Write-Host "ERROR: the language pack in the local cache is '$cacheHash', but -LangBundleHash is '$LangBundleHash'."
                Write-Host 'Publish the build this machine actually runs, or pass -SkipCacheCheck to force.'
                exit 1
            }
        }
        Write-Host "verified $($manifest.Count) source bundles against the local cache"
    }

    $zips = New-PrefabZips -PrefabDir $PrefabDir -OutDir $OutDir -TextZipName $PrefabZipName `
                           -ImageZipName $PrefabImagesZipName -Hash $LangBundleHash
    foreach ($k in $zips.Keys) { $pcBlock[$k] = $zips[$k] }
} else {
    Write-Host "no prefab build at $PrefabDir (build it with tools\prefab-patch\build_prefab_patch.py) - publishing without it"
}

# Merge into the live version.json, preserving the Android keys.
$versionPath = Join-Path $OutDir $VersionFile
Invoke-WebRequest -UseBasicParsing -Uri "$($ReleaseBase)/$($VersionFile)" -OutFile $versionPath
$version = Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json
# The pc_client copies are edited by hand between game builds, so taste a stale
# one here rather than shipping it: an older language bundle silently undoes
# tables the released one has fixed.
$prevLang = Get-Prop (Get-Prop $version 'pc').language_ja_en 'md5'
if ($prevLang -and $prevLang -ne $pcBlock.language_ja_en.md5) {
    Write-Host ''
    Write-Host "WARNING: the language bundle being published ($($pcBlock.language_ja_en.md5.Substring(0,8))...) differs"
    Write-Host "         from the released one ($($prevLang.Substring(0,8))...). Confirm the source is the"
    Write-Host '         newer build before publishing - a stale one regresses fixed tables.'
    Write-Host ''
}
$version | Add-Member -NotePropertyName pc -NotePropertyValue $pcBlock -Force
# Write BOM-free UTF-8: Set-Content -Encoding utf8 adds a BOM on Windows
# PowerShell 5.1, which breaks the Android app's minimal JSON parser.
[System.IO.File]::WriteAllText($versionPath,
    ($version | ConvertTo-Json -Depth 6),
    (New-Object System.Text.UTF8Encoding($false)))

Write-Host "staged in $OutDir :"
Get-ChildItem -LiteralPath $OutDir | ForEach-Object { Write-Host ("  {0}  {1} B" -f $_.Name, $_.Length) }
Write-Host "  pc.language_ja_en : $($pcBlock.language_ja_en.size) B  md5 $($pcBlock.language_ja_en.md5)"
Write-Host "  pc.inapp          : $($pcBlock.inapp_assets_all_en.size) B  md5 $($pcBlock.inapp_assets_all_en.md5)  stock md5 $($pcBlock.inapp_assets_all_en.stock_md5)"

if ($Publish) {
    # Assets first, version.json last: the installer reads version.json to learn
    # what to download, so it must never point at a file that is not uploaded yet.
    $assets = @($langDst, $inappDst)
    if ($pcBlock.Contains('prefab_patch')) { $assets += $prefabZip }
    if ($pcBlock.Contains('prefab_images')) { $assets += (Join-Path $OutDir $PrefabImagesZipName) }
    Write-Host "uploading assets to $ghRepo@$ghRelease ..."
    gh release upload $ghRelease @assets --repo $ghRepo --clobber
    if ($LASTEXITCODE -ne 0) { Write-Host 'ERROR: asset upload failed; version.json was NOT uploaded.'; exit 1 }
    Write-Host "uploading $VersionFile ..."
    gh release upload $ghRelease $versionPath --repo $ghRepo --clobber
    if ($LASTEXITCODE -ne 0) { Write-Host 'ERROR: version.json upload failed.'; exit 1 }
    Write-Host 'done.'
} else {
    Write-Host ''
    Write-Host 'Review the staged files, then publish with:'
    Write-Host "  powershell -File maintainer\Publish-PcPatch.ps1 -Publish"
}

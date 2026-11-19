<#
.SYNOPSIS
  Maintainer: publish the English PC menus + images (prefab-patch.zip, prefab-images.zip)
  built by tools\prefab-patch\build_pc_prefabs.py, without touching anything else.

.DESCRIPTION
  update_pipeline.py's publish carries the live pc.prefab_* entries over unchanged, so after
  a game update the English menus and images stay built for the old language pack. This
  zips the new tree (the same New-PrefabZips Publish-PcPatch.ps1 uses), then merges only
  pc.prefab_patch and pc.prefab_images into the live version.json, with the live
  pc.language_ja_en.hash as their hash. Every other key stays as it is.

  Refuses when the tree was built for another client build than -ClientBuild, or when the
  live version.json has no pc.language_ja_en block yet (publish the language pack first).
  Without -Publish it stages in -OutDir and prints the change; nothing is uploaded.
  With -Publish the zips go up first and version.json last, so an installer never sees a
  version.json that points at a file that is not there.

.EXAMPLE
  powershell -File tools\pc\maintainer\Publish-PcPrefabs.ps1 -PrefabDir build\prefab-patch-en -ClientBuild 202611180627fb4323a
  powershell -File tools\pc\maintainer\Publish-PcPrefabs.ps1 -PrefabDir build\prefab-patch-en -ClientBuild 202611180627fb4323a -Publish
#>
param(
    [Parameter(Mandatory)][string]$PrefabDir,
    # the game build the tree was built for (build_pc_prefabs.py writes it to source.json)
    [Parameter(Mandatory)][string]$ClientBuild,
    [string]$OutDir = (Join-Path $env:TEMP 'mt-pc-prefabs-release'),
    [switch]$Publish,
    [string]$Repo = 'Aikiooo/mt-en-applier',
    [string]$Release = 'patch-latest'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'PrefabZips.ps1')
$ghRepo = $Repo
$ghRelease = $Release

$src = Join-Path $PrefabDir 'source.json'
if (-not (Test-Path -LiteralPath $src)) { throw "no source.json in $PrefabDir (build it with build_pc_prefabs.py)" }
$source = Get-Content -LiteralPath $src -Raw -Encoding UTF8 | ConvertFrom-Json
if ($source.client_build -ne $ClientBuild) { throw "$PrefabDir was built for client $($source.client_build), not $ClientBuild" }
if (-not (Test-Path -LiteralPath (Join-Path $PrefabDir 'manifest.json'))) { throw "no manifest.json in $PrefabDir" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$versionPath = Join-Path $OutDir 'version.json'
Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$ghRepo/releases/download/$ghRelease/version.json?t=$([DateTime]::UtcNow.Ticks)" -OutFile $versionPath
$version = Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$lang = $version.pc.language_ja_en
if (-not $lang -or -not $lang.hash) { throw 'the live version.json has no pc.language_ja_en: publish the language pack first' }

$zips = New-PrefabZips -PrefabDir $PrefabDir -OutDir $OutDir -TextZipName 'prefab-patch.zip' `
                       -ImageZipName 'prefab-images.zip' -Hash $lang.hash
foreach ($k in 'prefab_patch', 'prefab_images') {
    if (-not $zips.Contains($k)) { Write-Host "  pc.$k : none in this build, left as it is"; continue }
    $was = $version.pc.PSObject.Properties[$k]
    Write-Host ("  pc.{0}: {1} -> {2} ({3} bundles, hash {4})" -f $k, $(if ($was) { $was.Value.md5 } else { 'absent' }), $zips[$k].md5, $zips[$k].bundles, $zips[$k].hash)
    $version.pc | Add-Member -NotePropertyName $k -NotePropertyValue $zips[$k] -Force
}
[System.IO.File]::WriteAllText($versionPath, ($version | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

if (-not $Publish) { Write-Host "staged in $OutDir; nothing uploaded (add -Publish)"; exit 0 }
$assets = @((Join-Path $OutDir 'prefab-patch.zip'), (Join-Path $OutDir 'prefab-images.zip'))
Write-Host "uploading $($assets.Count) zips to $ghRepo@$ghRelease ..."
gh release upload $ghRelease @assets --repo $ghRepo --clobber
if ($LASTEXITCODE -ne 0) { throw 'zip upload failed; version.json was NOT uploaded' }
gh release upload $ghRelease $versionPath --repo $ghRepo --clobber
if ($LASTEXITCODE -ne 0) { throw 'version.json upload failed' }
Write-Host 'done.'

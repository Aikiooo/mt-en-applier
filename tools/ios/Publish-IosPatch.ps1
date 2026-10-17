<#
.SYNOPSIS
  Maintainer: upload the iOS patch built by build_ios_patch.py to the rolling ios-latest release.

.DESCRIPTION
  Uploads every file of -BuildDir (the patched bundles, ios-manifest.json, mt-en-ios.yaml,
  mt-en-ios.sgmodule) and MT-EN-iOS.zip (the players' PC tool from tools/ios/pc, made here
  with this release as its default source) to the ios-latest release of -Repo, creating it
  as a prerelease the first time (so it never becomes the app's "latest"), then deletes the
  bundles of earlier builds that the new manifest no longer names. The PC tool reads
  .../releases/download/ios-latest/ios-manifest.json at each start, so players pick the new
  build up by running it again.

  Checks before uploading (nothing is sent if one fails): the manifest and both modules
  exist, every manifest file is present with its out_md5, and both modules name exactly
  the manifest files under -Repo's ios-latest URL.

.EXAMPLE
  powershell -File tools\ios\Publish-IosPatch.ps1 -BuildDir build\ios
#>
param(
    [string]$BuildDir = "build\ios",
    [string]$Repo = "Aikiooo/mt-en-applier",
    [string]$Tag = "ios-latest"
)
$ErrorActionPreference = "Stop"

$manifest = Get-Content (Join-Path $BuildDir "ios-manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$base = "https://github.com/$Repo/releases/download/$Tag/"
$names = @($manifest.files | ForEach-Object { $_.file })
foreach ($f in $manifest.files) {
    $p = Join-Path $BuildDir $f.file
    if (-not (Test-Path $p)) { throw "missing $($f.file)" }
    $md5 = (Get-FileHash $p -Algorithm MD5).Hash.ToLower()
    if ($md5 -ne $f.out_md5) { throw "$($f.file): MD5 $md5, manifest says $($f.out_md5)" }
}
foreach ($m in "mt-en-ios.yaml", "mt-en-ios.sgmodule") {
    $text = Get-Content (Join-Path $BuildDir $m) -Raw -Encoding UTF8
    $targets = @([regex]::Matches($text, [regex]::Escape($base) + "([^\s']+)") | ForEach-Object { $_.Groups[1].Value })
    if (Compare-Object ($targets | Sort-Object) ($names | Sort-Object)) {
        throw "$m doesn't point every manifest file at $base (built with another --release-url?)"
    }
}
Write-Host "$($names.Count) bundles OK (client build $($manifest.client_build), built $($manifest.built_at))"

# The players' PC tool, with this release as the default source of the patched files
$pc = Join-Path $PSScriptRoot "pc"
$stage = Join-Path $BuildDir "MT-EN-iOS"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $pc "Installer-iOS.bat"), (Join-Path $pc "mt_en_ios.py") $stage
$ps = Get-Content (Join-Path $pc "Installer-iOS.ps1") -Raw -Encoding UTF8
$default = "https://github.com/Aikiooo/mt-en-applier/releases/download/ios-latest"
if (-not $ps.Contains($default)) { throw "Installer-iOS.ps1: default release URL not found" }
[IO.File]::WriteAllText((Join-Path $stage "Installer-iOS.ps1"), $ps.Replace($default, $base.TrimEnd("/")), (New-Object Text.UTF8Encoding $true))
$zip = Join-Path $BuildDir "MT-EN-iOS.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip

# gh's own exit codes decide from here: with "Stop", Windows PowerShell 5.1 aborts on any stderr line
$ErrorActionPreference = "Continue"
$null = gh release view $Tag --repo $Repo 2>&1
if ($LASTEXITCODE -ne 0) {
    gh release create $Tag --repo $Repo --prerelease --title "iOS English Patch" `
        --notes "Rolling iOS build. Players: download MT-EN-iOS.zip and follow docs/INSTALL-iOS.md."
    if ($LASTEXITCODE -ne 0) { throw "gh release create failed" }
}
$files = @($names | ForEach-Object { Join-Path $BuildDir $_ }) +
         @("ios-manifest.json", "MT-EN-iOS.zip", "mt-en-ios.yaml", "mt-en-ios.sgmodule" | ForEach-Object { Join-Path $BuildDir $_ })
# bundles first, modules last: a module never points at a file that isn't up yet
for ($i = 0; $i -lt $files.Count; $i += 50) {
    gh release upload $Tag --repo $Repo --clobber @($files[$i..([Math]::Min($i + 49, $files.Count - 1))])
    if ($LASTEXITCODE -ne 0) { throw "upload failed" }
}
$keep = @($names) + "ios-manifest.json", "MT-EN-iOS.zip", "mt-en-ios.yaml", "mt-en-ios.sgmodule"
$old = gh release view $Tag --repo $Repo --json assets --jq ".assets[].name" | Where-Object { $_ -notin $keep }
foreach ($a in $old) { gh release delete-asset $Tag $a --repo $Repo --yes }
Write-Host "published: $base`MT-EN-iOS.zip ($($old.Count) old files removed)"

<#
.SYNOPSIS
  Maintainer: build, verify and (with -Publish) release the Android app.

.DESCRIPTION
  Makes an app release hard to get wrong. The in-app update check looks for the
  highest vX.Y.Z release that carries an asset named exactly MT-EN-Applier.apk,
  and Android only installs an update signed with the SAME key as the installed
  copy, so every check below is a hard refusal (nothing is uploaded):

    - git tree clean, on 'main', and HEAD identical to origin/main (pushed)
    - tag v<versionName> does not exist locally, on origin, or as a GitHub release
    - the release key properties file exists (app/build.gradle signs with it)
    - the built APK's package, versionName and versionCode match app/build.gradle
    - the APK is signed with the v2 scheme and the signer certificate SHA-256 is
      the project key ($ExpectedCertSha256 below). Older releases used a debug
      key; a different key would force every user to uninstall first.

  Version comes from app/build.gradle (versionName / versionCode); the tag is
  "v" + versionName.

  Staging (default): builds with gradlew assembleRelease, runs the checks and
  writes to -OutDir: MT-EN-Applier.apk, INSTALL.md and (if given) the notes.

  INSTALL.md: docs/INSTALL.md is the versioned source and is NEVER edited by this
  script. Its "File check" paragraph carries the APK version, size, MD5 and
  signing cert; the script rewrites those four values in the STAGED copy only,
  so the attached file is always right. If the paragraph can't be found or a
  value can't be replaced exactly once, it fails with a message instead of
  guessing. (Other version-specific prose in docs/INSTALL.md, e.g. an "Updating
  from" banner, is yours to review before releasing.)

  -Publish: gh release create <tag> <apk> <install> --target main --latest, then
  re-downloads .../releases/latest/download/MT-EN-Applier.apk and checks its MD5
  equals the staged one.

.EXAMPLE
  # stage and verify (no upload)
  powershell -File tools\Release-App.ps1

.EXAMPLE
  # release for real
  powershell -File tools\Release-App.ps1 -Notes D:\notes\v2.5.0.md -Publish

.EXAMPLE
  # testing only: run build/sign/badging checks despite a dirty tree / existing tag
  powershell -File tools\Release-App.ps1 -TestSkipGitChecks
  powershell -File tools\Release-App.ps1 -TestSkipGitChecks -TestApk app\build\outputs\apk\debug\app-debug.apk
#>
param(
    # Release notes (markdown). Required for -Publish.
    [string]$Notes,
    [switch]$Publish,
    [string]$Repo = 'Aikiooo/mt-en-applier',
    [string]$OutDir = (Join-Path $env:TEMP 'mt-app-release'),
    # Release key properties (passed to Gradle as -PmtReleaseProps). Default is what
    # app/build.gradle already uses.
    [string]$ReleaseProps = (Join-Path $env:USERPROFILE '.android\mt-en-applier-release.properties'),
    # TESTING ONLY: skip git/tag/release-exists checks. Refused together with -Publish.
    [switch]$TestSkipGitChecks,
    # TESTING ONLY: check this APK instead of building. Refused together with -Publish.
    [string]$TestApk
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ExpectedCertSha256 = '96:84:57:15:19:B4:00:5E:98:EC:43:32:B7:F6:EF:69:D2:2E:8E:30:F0:30:11:57:56:16:5A:80:9E:F2:0D:B1'
$ExpectedPackage = 'com.mtpatch.enapply'
$ApkFile = 'MT-EN-Applier.apk'
$InstallSrc = Join-Path $repoRoot 'docs\INSTALL.md'
$builtApk = Join-Path $repoRoot 'app\build\outputs\apk\release\app-release.apk'

function Fail([string]$Msg) { Write-Host "ERROR: $Msg"; exit 1 }

# .NET MD5, not Get-FileHash: launched as `powershell -File` from PowerShell 7,
# Windows PowerShell inherits pwsh's PSModulePath and can't autoload it.
function Get-Md5([string]$Path) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { ($md5.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $fs.Close(); $md5.Dispose() }
}

# Run a native command, return @{ Code; Out } without tripping $ErrorActionPreference
# on stderr output (Windows PowerShell 5.1 turns native stderr into errors).
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    @{ Code = $code; Out = ($out -join "`n") }
}

function Invoke-Git([string[]]$Arguments) { Invoke-Native 'git' (@('-C', $repoRoot) + $Arguments) }

if ($Publish -and ($TestSkipGitChecks -or $TestApk)) { Fail '-TestSkipGitChecks / -TestApk are testing-only and cannot be combined with -Publish' }
if ($Publish -and -not $Notes) { Fail '-Publish needs -Notes <file>' }
if ($Notes -and -not (Test-Path -LiteralPath $Notes)) { Fail "notes file not found: $Notes" }
if (-not (Test-Path -LiteralPath $InstallSrc)) { Fail "missing $InstallSrc (the versioned INSTALL.md)" }

# --- version ---------------------------------------------------------------------
$gradle = Get-Content -LiteralPath (Join-Path $repoRoot 'app\build.gradle') -Raw
$mName = [regex]::Match($gradle, 'versionName\s+"([^"]+)"')
$mCode = [regex]::Match($gradle, 'versionCode\s+(\d+)')
if (-not $mName.Success -or -not $mCode.Success) { Fail 'could not read versionName/versionCode from app/build.gradle' }
$versionName = $mName.Groups[1].Value
$versionCode = $mCode.Groups[1].Value
if ($versionName -notmatch '^\d+\.\d+\.\d+$') { Fail "versionName '$versionName' is not X.Y.Z; the update check needs vX.Y.Z tags" }
$tag = "v$versionName"
Write-Host "app/build.gradle: versionName $versionName, versionCode $versionCode -> tag $tag"

# --- git / release state ---------------------------------------------------------
if ($TestSkipGitChecks) {
    Write-Host 'WARNING: -TestSkipGitChecks: git, tag and release-exists checks SKIPPED (testing only)'
} else {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail 'git not found' }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail 'gh (GitHub CLI) not found' }

    $dirty = (Invoke-Git @('status', '--porcelain')).Out.Trim()
    if ($dirty) { Fail "git tree is dirty; commit or stash first:`n$dirty" }

    $branch = (Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')).Out.Trim()
    if ($branch -ne 'main') { Fail "on branch '$branch'; releases are cut from 'main'" }

    $f = Invoke-Git @('fetch', 'origin', 'main', '--tags', '--quiet')
    if ($f.Code -ne 0) { Fail "git fetch origin failed:`n$($f.Out)" }
    $ahead = [int](Invoke-Git @('rev-list', '--count', 'origin/main..HEAD')).Out.Trim()
    $behind = [int](Invoke-Git @('rev-list', '--count', 'HEAD..origin/main')).Out.Trim()
    if ($ahead -gt 0) { Fail "main is $ahead commit(s) ahead of origin/main; push first so the release matches what is public" }
    if ($behind -gt 0) { Fail "main is $behind commit(s) behind origin/main; pull first" }

    if ((Invoke-Git @('tag', '-l', $tag)).Out.Trim()) { Fail "tag $tag already exists locally (bump versionName/versionCode in app/build.gradle)" }
    $remoteTag = Invoke-Git @('ls-remote', '--tags', 'origin', "refs/tags/$tag")
    if ($remoteTag.Code -ne 0) { Fail "git ls-remote failed:`n$($remoteTag.Out)" }
    if ($remoteTag.Out.Trim()) { Fail "tag $tag already exists on origin (bump versionName/versionCode in app/build.gradle)" }
    $rel = Invoke-Native 'gh' @('release', 'view', $tag, '--repo', $Repo)
    if ($rel.Code -eq 0) { Fail "GitHub release $tag already exists in $Repo (bump versionName/versionCode in app/build.gradle)" }
    Write-Host "git OK: clean, main == origin/main, $tag is new"
}

# --- build tools -----------------------------------------------------------------
$btRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk\build-tools'
if (-not (Test-Path -LiteralPath $btRoot)) { Fail "Android build-tools not found at $btRoot" }
$bt = Get-ChildItem -LiteralPath $btRoot -Directory |
    Where-Object { $_.Name -match '^\d+(\.\d+)*$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $bt) { Fail "no build-tools versions under $btRoot" }
$apksignerJar = Join-Path $bt.FullName 'lib\apksigner.jar'
$aapt2 = Join-Path $bt.FullName 'aapt2.exe'
foreach ($t in @($apksignerJar, $aapt2)) { if (-not (Test-Path -LiteralPath $t)) { Fail "missing $t" } }
if (-not (Get-Command java -ErrorAction SilentlyContinue)) { Fail 'java not found (needed for apksigner)' }
Write-Host "build-tools $($bt.Name)"

# --- build -----------------------------------------------------------------------
if ($TestApk) {
    if (-not (Test-Path -LiteralPath $TestApk)) { Fail "-TestApk not found: $TestApk" }
    $apk = (Resolve-Path -LiteralPath $TestApk).Path
    Write-Host "WARNING: -TestApk: checking $apk instead of building (testing only)"
} else {
    if (-not (Test-Path -LiteralPath $ReleaseProps)) {
        Fail "release key properties not found: $ReleaseProps (without it Gradle builds an UNSIGNED release; see app/build.gradle)"
    }
    if (Test-Path -LiteralPath $builtApk) { Remove-Item -LiteralPath $builtApk -Force }
    Write-Host 'gradlew.bat assembleRelease ...'
    Push-Location $repoRoot
    try {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & (Join-Path $repoRoot 'gradlew.bat') assembleRelease "-PmtReleaseProps=$ReleaseProps" 2>&1 | ForEach-Object { Write-Host "  $_" }
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
    } finally { Pop-Location }
    if ($code -ne 0) { Fail "gradle assembleRelease failed (exit $code)" }
    if (-not (Test-Path -LiteralPath $builtApk)) { Fail "build succeeded but $builtApk is missing (unsigned builds are named app-release-unsigned.apk)" }
    $apk = $builtApk
}

# --- verify APK ------------------------------------------------------------------
$badge = Invoke-Native $aapt2 @('dump', 'badging', $apk)
if ($badge.Code -ne 0) { Fail "aapt2 dump badging failed:`n$($badge.Out)" }
$pm = [regex]::Match($badge.Out, "package: name='([^']*)' versionCode='([^']*)' versionName='([^']*)'")
if (-not $pm.Success) { Fail 'could not parse aapt2 badging output' }
$apkPkg = $pm.Groups[1].Value; $apkCode = $pm.Groups[2].Value; $apkVerName = $pm.Groups[3].Value
if ($apkPkg -ne $ExpectedPackage) { Fail "APK package is '$apkPkg', expected '$ExpectedPackage'" }
if ($apkVerName -ne $versionName) { Fail "APK versionName '$apkVerName' != app/build.gradle '$versionName' (stale build?)" }
if ($apkCode -ne $versionCode) { Fail "APK versionCode '$apkCode' != app/build.gradle '$versionCode' (stale build?)" }
Write-Host "badging OK: $apkPkg versionName $apkVerName versionCode $apkCode"

$sig = Invoke-Native 'java' @('-jar', $apksignerJar, 'verify', '--verbose', '--print-certs', $apk)
if ($sig.Code -ne 0) { Fail "apksigner verify failed (unsigned or broken signature):`n$($sig.Out)" }
if ($sig.Out -notmatch 'v2 scheme[^\r\n]*:\s*true') { Fail "APK is not signed with the v2 scheme:`n$($sig.Out)" }
$cm = [regex]::Match($sig.Out, 'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]+)')
if (-not $cm.Success) { Fail "could not read the signer certificate from apksigner:`n$($sig.Out)" }
$certHex = $cm.Groups[1].Value.ToUpperInvariant()
$certColon = ($certHex -replace '(..)(?!$)', '$1:')
if ($certColon -ne $ExpectedCertSha256) {
    Fail "signer certificate SHA-256 is`n  $certColon`nbut the project key is`n  $ExpectedCertSha256`nRefusing: users could not update over their installed copy."
}
Write-Host 'signature OK: v2 scheme, project key'

# --- stage -----------------------------------------------------------------------
$size = (Get-Item -LiteralPath $apk).Length
$md5 = Get-Md5 $apk
if (Test-Path -LiteralPath $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stagedApk = Join-Path $OutDir $ApkFile
$stagedInstall = Join-Path $OutDir 'INSTALL.md'
Copy-Item -LiteralPath $apk -Destination $stagedApk -Force
if ((Get-Md5 $stagedApk) -ne $md5) { Fail 'staged APK differs from the built one' }

# Rewrite the "File check" paragraph's values in the STAGED copy only.
$utf8 = New-Object System.Text.UTF8Encoding($false)
$text = [System.IO.File]::ReadAllText($InstallSrc, $utf8)
$pb = [regex]::Match($text, '\*\*File check \(optional\):\*\*[\s\S]*?(?=\r?\n[ \t]*\r?\n|$)')
if (-not $pb.Success) { Fail "docs/INSTALL.md has no '**File check (optional):**' paragraph to update" }
$para = $pb.Value
$sizeText = $size.ToString('N0', [System.Globalization.CultureInfo]::InvariantCulture)
$subs = @(
    @('version', '(?<=MT-EN-Applier\.apk` )v\d+\.\d+\.\d+', $tag),
    @('size',    '[\d,]+(?= bytes)', $sizeText),
    @('MD5',     '(?<=MD5 `)[0-9a-fA-F]{32}(?=`)', $md5),
    @('cert',    '(?<=SHA-256\s+`)[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){31}(?=`)', $certColon)
)
foreach ($s in $subs) {
    $n = ([regex]::Matches($para, $s[1])).Count
    if ($n -ne 1) { Fail "docs/INSTALL.md 'File check' paragraph: expected exactly one $($s[0]) value to update, found $n. Fix the paragraph format." }
    $para = [regex]::Replace($para, $s[1], $s[2].Replace('$', '$$'))
}
$newText = $text.Substring(0, $pb.Index) + $para + $text.Substring($pb.Index + $pb.Length)
[System.IO.File]::WriteAllText($stagedInstall, $newText, $utf8)
if ($newText -ne $text) { Write-Host 'INSTALL.md: File check line rewritten in the staged copy (docs/INSTALL.md untouched)' }
else { Write-Host 'INSTALL.md: File check line already matched' }

$stagedNotes = $null
if ($Notes) {
    $stagedNotes = Join-Path $OutDir 'notes.md'
    Copy-Item -LiteralPath $Notes -Destination $stagedNotes -Force
}

Write-Host ''
Write-Host "staged in $OutDir"
Write-Host "  tag      : $tag"
Write-Host "  apk      : $stagedApk"
Write-Host ("  size     : {0} bytes" -f $sizeText)
Write-Host "  md5      : $md5"
Write-Host "  signer   : $certColon"
Write-Host "  install  : $stagedInstall"
if ($stagedNotes) { Write-Host "  notes    : $stagedNotes" }
else { Write-Host '  notes    : (none; -Notes is required for -Publish)' }

# --- publish ---------------------------------------------------------------------
if (-not $Publish) {
    Write-Host ''
    Write-Host 'Dry run: nothing uploaded. Re-run with -Notes <file> -Publish to release.'
    exit 0
}

Write-Host ''
Write-Host "gh release create $tag ..."
$r = Invoke-Native 'gh' @('release', 'create', $tag, $stagedApk, $stagedInstall,
    '--repo', $Repo, '--target', 'main', '--title', "MT-EN Applier $tag",
    '--notes-file', $stagedNotes, '--latest')
Write-Host $r.Out
if ($r.Code -ne 0) { Fail "gh release create failed (exit $($r.Code))" }

# Re-download through the URL the app uses and compare.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$url = "https://github.com/$Repo/releases/latest/download/$ApkFile"
$dl = Join-Path $OutDir 'verify-download.apk'
$remoteMd5 = $null
for ($i = 1; $i -le 5 -and $remoteMd5 -ne $md5; $i++) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $dl -UseBasicParsing
        $remoteMd5 = Get-Md5 $dl
    } catch { Write-Host "  download attempt $i failed: $($_.Exception.Message)" }
    if ($remoteMd5 -ne $md5 -and $i -lt 5) { Start-Sleep -Seconds 5 }
}
if ($remoteMd5 -ne $md5) { Fail "re-downloaded $url has md5 '$remoteMd5', staged was '$md5'. Check the release by hand." }
Write-Host "verified: $url md5 $remoteMd5 matches the staged APK"
Write-Host "released $tag"

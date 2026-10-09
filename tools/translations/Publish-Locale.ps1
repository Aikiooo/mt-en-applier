<#
.SYNOPSIS
  Maintainer: publish one non-English patch language to the rolling
  'patch-latest' release, so the Android app offers it in its language picker.

.DESCRIPTION
  The app only lists languages that version.json on the release names under a
  nested "locales" block (English stays the historic top-level keys, so older
  app versions are unaffected). This script:

    1. builds translation_cache.<locale>.json from translations/<locale>/
       (Build-TranslationCache.ps1; untranslated keys fall back to English),
    2. optionally stages a ready-made __data.<locale> for the app's Download
       button (-PatchFile, or -BuildPatch to build one with the app's own
       AutoPatcher engine),
    3. merges a "locales.<locale>" block into the live version.json, leaving
       every other key (Android top level, "pc", other locales) untouched,
    4. with -Publish, uploads the assets first and version.json last, so the
       app never sees a language whose files aren't on the release yet.

  Without a patch the language is "Auto-patch only": the app builds it on the
  phone from the live game bundle + this cache.

  update_translation.py rewrites version.json from scratch on every English
  release, which drops the "locales" block. Re-run this script for each
  published language after an English release.

.EXAMPLE
  # cache only (Auto-patch); stage and review
  powershell -File tools\translations\Publish-Locale.ps1 -Locale es

.EXAMPLE
  # with a ready-made bundle built elsewhere for the current game build
  powershell -File tools\translations\Publish-Locale.ps1 -Locale es -PatchFile D:\out\__data_es -Stock D:\stock\__data_v13_android -Publish

.EXAMPLE
  # also offer it on PC (exact-size, CRC-forged bundle for the current PC build)
  powershell -File tools\translations\Publish-Locale.ps1 -Locale es -PcPatchFile D:\out\language-ja_es.bundle -Publish

.EXAMPLE
  # build the bundle with AutoPatcher (grown, NOT exact-size: test on a phone first)
  powershell -File tools\translations\Publish-Locale.ps1 -Locale es -BuildPatch -Stock D:\stock\__data_v13_android -KeysJson D:\keys\masterdata_keys.json

.EXAMPLE
  # withdraw a language from the app (assets stay on the release, unlisted)
  powershell -File tools\translations\Publish-Locale.ps1 -Locale es -Unpublish -Publish
#>
param(
    [Parameter(Mandatory = $true)][string]$Locale,
    # A ready-made Android __data for this locale.
    [string]$PatchFile,
    # A ready-made PC (DMM) language bundle for this locale: exact stock size +
    # forged CRC like the English one, built for the release's current PC game build.
    [string]$PcPatchFile,
    # Build __data.<locale> with AutoPatchMain (needs -Stock and -KeysJson).
    [switch]$BuildPatch,
    # The Android-target stock bundle the patch is (or gets) built from. Its md5
    # is recorded so the app can hide the download once the game updates.
    [string]$Stock,
    # Instead of -Stock when only the md5 is known.
    [string]$StockMd5,
    # {"key_hex": ..., "iv_hex": ...} for -BuildPatch.
    [string]$KeysJson,
    [string]$Lz4Jar,
    [switch]$Unpublish,
    # Publish even if nothing is translated yet, or the stock isn't the release's.
    [switch]$Force,
    [string]$OutDir = (Join-Path $env:TEMP 'mt-locale-release'),
    [switch]$Publish,
    [string]$Repo = 'Aikiooo/mt-en-applier',
    [string]$Release = 'patch-latest'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$translationsRoot = Join-Path $repoRoot 'translations'
$releaseBase = "https://github.com/$Repo/releases/download/$Release"

function Get-Md5([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash.ToLowerInvariant()
}

function Fail([string]$Msg) { Write-Host "ERROR: $Msg"; exit 1 }

# --- locale ---------------------------------------------------------------------
$registry = Get-Content -LiteralPath (Join-Path $translationsRoot 'locales.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$default = $registry.default
$entry = $registry.locales.$Locale
if (-not $entry) { Fail "unknown locale '$Locale' (add it to translations/locales.json first)" }
if ($Locale -eq $default) { Fail "'$default' is the default language; it ships through update_translation.py" }
# The app rejects anything else (codes become file names on the phone).
if ($Locale -notmatch '^[A-Za-z0-9_-]{1,16}$') { Fail "locale code '$Locale' must match [A-Za-z0-9_-]{1,16}" }
if ($PatchFile -and $BuildPatch) { Fail "use -PatchFile or -BuildPatch, not both" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$versionPath = Join-Path $OutDir 'version.json'
Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/version.json" -OutFile $versionPath
$version = Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json

$cacheName = "translation_cache.$Locale.json"
$patchName = "__data.$Locale"
$upload = @()

if ($Unpublish) {
    if ($version.locales -and $version.locales.PSObject.Properties[$Locale]) {
        $version.locales.PSObject.Properties.Remove($Locale)
    }
    Write-Host "locale '$Locale' removed from version.json (release assets left in place, unlisted)"
} else {
    # --- coverage guard: never publish English under another language's name --
    function Count-Entries([string]$Dir) {
        $n = 0
        if (Test-Path -LiteralPath $Dir) {
            foreach ($f in Get-ChildItem -LiteralPath $Dir -Filter *.json) {
                $obj = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $n += @($obj.PSObject.Properties).Count
            }
        }
        return $n
    }
    $total = Count-Entries (Join-Path $translationsRoot "$default\source")
    $done = Count-Entries (Join-Path $translationsRoot "$Locale\source")
    $pct = if ($total) { [math]::Round(100.0 * $done / $total, 1) } else { 0 }
    Write-Host "locale '$Locale': $done / $total entries translated ($pct%), the rest falls back to English"
    if ($done -eq 0 -and -not $Force) { Fail "nothing translated for '$Locale' yet (pass -Force to publish anyway)" }

    # --- 1. translation cache ---------------------------------------------------
    $cachePath = Join-Path $OutDir $cacheName
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Build-TranslationCache.ps1') `
        -Locale $Locale -Out $cachePath
    if ($LASTEXITCODE -ne 0) { Fail "cache build failed for '$Locale'" }
    $upload += $cachePath

    $block = [ordered]@{
        name      = $entry.name
        cache     = $cacheName
        cache_md5 = Get-Md5 $cachePath
        built_at  = (Get-Date).ToString('s')
    }

    # --- 2. optional ready-made __data ------------------------------------------
    if ($Stock) {
        if (-not (Test-Path -LiteralPath $Stock)) { Fail "missing stock: $Stock" }
        $StockMd5 = Get-Md5 $Stock
    }
    $patchPath = Join-Path $OutDir $patchName
    if ($BuildPatch) {
        if (-not $Stock -or -not $KeysJson) { Fail "-BuildPatch needs -Stock and -KeysJson" }
        if (-not (Test-Path -LiteralPath $KeysJson)) { Fail "missing keys: $KeysJson" }
        if (-not (Get-Command javac -ErrorAction SilentlyContinue)) { Fail "javac not on PATH (JDK 17+ needed)" }
        if (-not $Lz4Jar) {
            $Lz4Jar = Get-ChildItem -Path (Join-Path $env:USERPROFILE '.gradle\caches\modules-2\files-2.1\org.lz4\lz4-java') `
                -Recurse -Filter 'lz4-java-*.jar' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch 'sources|javadoc' } | Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $Lz4Jar) { Fail "lz4-java jar not found; build the app once with Gradle or pass -Lz4Jar" }

        $classes = Join-Path $OutDir 'autopatcher-classes'
        if (Test-Path -LiteralPath $classes) { Remove-Item -LiteralPath $classes -Recurse -Force }
        New-Item -ItemType Directory -Path $classes | Out-Null
        $core = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'app\src\main\java\com\mtpatch\enapply\core') -Filter *.java |
            ForEach-Object { $_.FullName }
        & javac -nowarn -encoding UTF-8 -d $classes -cp $Lz4Jar @core
        if ($LASTEXITCODE -ne 0) { Fail "javac failed" }
        $tables = Join-Path $repoRoot 'app\src\main\assets\tables.txt'
        & java -cp "$classes;$Lz4Jar" com.mtpatch.enapply.core.AutoPatchMain `
            $Stock $KeysJson $cachePath $tables $patchPath |
            Where-Object { $_ -notmatch ': (fit_after_revert|not found|ambiguous)' }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $patchPath)) { Fail "AutoPatchMain failed" }
        if ((Get-Item $patchPath).Length -ne (Get-Item $Stock).Length) {
            Write-Host ''
            Write-Host "WARNING: $patchName is $((Get-Item $patchPath).Length) B, the stock is $((Get-Item $Stock).Length) B."
            Write-Host '         The shipped English build is exact-size + CRC-forged; a grown bundle has not'
            Write-Host '         been validated on Android. Apply it on a phone and launch the game BEFORE -Publish.'
            Write-Host ''
        }
    } elseif ($PatchFile) {
        if (-not (Test-Path -LiteralPath $PatchFile)) { Fail "missing patch: $PatchFile" }
        Copy-Item -LiteralPath $PatchFile -Destination $patchPath -Force
    }

    if ($BuildPatch -or $PatchFile) {
        if (-not $StockMd5) { Fail "pass -Stock (or -StockMd5) so the app can tell when this patch goes stale" }
        $StockMd5 = $StockMd5.ToLowerInvariant()
        if ($version.stock_md5 -and $StockMd5 -ne $version.stock_md5.ToLowerInvariant() -and -not $Force) {
            Fail "patch stock md5 $StockMd5 != release stock_md5 $($version.stock_md5): built for another game build (-Force overrides; the app would hide the download anyway)"
        }
        $block.patch      = $patchName
        $block.patch_size = (Get-Item $patchPath).Length
        $block.patch_md5  = Get-Md5 $patchPath
        $block.stock_md5  = $StockMd5
        $upload += $patchPath
    } else {
        Write-Host "no patch: '$Locale' will be offered as Auto-patch only"
    }

    # --- 2b. optional PC bundle (read by tools/pc/Install-EnPatch.ps1) ---------
    if ($PcPatchFile) {
        if (-not (Test-Path -LiteralPath $PcPatchFile)) { Fail "missing PC patch: $PcPatchFile" }
        $en = $version.pc.language_ja_en
        $pcSize = (Get-Item -LiteralPath $PcPatchFile).Length
        # The PC catalog pins the bundle size; anything else fails to load.
        if ($pcSize -ne [int64]$en.size -and -not $Force) {
            Fail "PC bundle is $pcSize B but the current PC build needs exactly $($en.size) B (-Force overrides)"
        }
        $pcName = "language-ja_$Locale.bundle"
        $pcPath = Join-Path $OutDir $pcName
        Copy-Item -LiteralPath $PcPatchFile -Destination $pcPath -Force
        $block.pc = [ordered]@{
            language = [ordered]@{ file = $pcName; size = $pcSize; md5 = Get-Md5 $pcPath; hash = $en.hash }
        }
        $upload += $pcPath
    }

    # --- 3. merge into version.json ---------------------------------------------
    if (-not $version.locales) {
        $version | Add-Member -NotePropertyName locales -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $version.locales | Add-Member -NotePropertyName $Locale -NotePropertyValue ([pscustomobject]$block) -Force
}

# Write BOM-free UTF-8: Set-Content -Encoding utf8 adds a BOM on Windows
# PowerShell 5.1, which breaks the Android app's minimal JSON parser.
[System.IO.File]::WriteAllText($versionPath,
    ($version | ConvertTo-Json -Depth 8),
    (New-Object System.Text.UTF8Encoding($false)))

Write-Host "staged in $OutDir :"
foreach ($f in $upload + $versionPath) { Write-Host ("  {0}  {1} B" -f (Split-Path -Leaf $f), (Get-Item $f).Length) }
if ($version.locales) {
    Write-Host 'published languages after this run:'
    foreach ($p in $version.locales.PSObject.Properties) {
        $mode = if ($p.Value.PSObject.Properties['patch']) { 'Download + Auto-patch' } else { 'Auto-patch only' }
        if ($p.Value.PSObject.Properties['pc']) { $mode += ' + PC' }
        Write-Host "  $($p.Name)  $($p.Value.name)  ($mode)"
    }
}

if ($Publish) {
    Write-Host "uploading to $Repo@$Release ..."
    # assets first, version.json last: the app must never list a missing file
    if ($upload.Count) {
        gh release upload $Release @upload --repo $Repo --clobber
        if ($LASTEXITCODE -ne 0) { Fail "asset upload failed; version.json NOT updated" }
    }
    gh release upload $Release $versionPath --repo $Repo --clobber
    if ($LASTEXITCODE -ne 0) { Fail "version.json upload failed" }
    Write-Host 'done.'
} else {
    Write-Host ''
    Write-Host 'Review the staged files, then re-run with -Publish.'
}

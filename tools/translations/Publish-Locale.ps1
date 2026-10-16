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
  # build the PC bundle from the released English one (tools/prefab-patch/build_locale_bundle.py)
  powershell -File tools\translations\Publish-Locale.ps1 -Locale fr -BuildPcPatch -Publish

.EXAMPLE
  # the whole PC patch: language bundle, UI prefabs + images, in-app title screen
  # (built with build_prefab_patch.py / build_inapp.py from this locale's cache,
  # translations/fr/prefab/ui-prefab.json and translations/fr/textures/)
  powershell -File tools\translations\Publish-Locale.ps1 -Locale fr -BuildPcPatch `
      -PcPrefabDir build\prefab-patch-fr -PcInappBuild build\inapp_assets_all_fr.bundle -Publish

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
    # Build that PC bundle here instead: the released English bundle with this
    # locale's tables, exact-size and CRC-forged (needs Python with
    # tools/prefab-patch/requirements.txt, and the PC game installed for the
    # master key, or -PcMetadata).
    [switch]$BuildPcPatch,
    # global-metadata.dat of the PC client, when the game isn't installed here.
    [string]$PcMetadata,
    # This locale's UI prefab tree (manifest.json + <name>\<hash>\__data), from
    # tools/prefab-patch/build_prefab_patch.py run with this locale's cache,
    # prefab map and textures. Published as prefab-patch-<locale>.zip and
    # prefab-images-<locale>.zip; the PC installer offers them like English's.
    [string]$PcPrefabDir,
    # This locale's in-app bundle (tools/prefab-patch/build_inapp.py), with the
    # .json build_inapp.py writes beside it. Published as
    # inapp_assets_all_<locale>.bundle for the installer's title-screen swap.
    [string]$PcInappBuild,
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
    # Java LZMA decoder for -BuildPatch (the game's own bundles use LZMA blocks).
    [string]$XzJar,
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

# .NET MD5, not Get-FileHash: launched as `powershell -File` from PowerShell 7,
# Windows PowerShell inherits pwsh's PSModulePath and can't autoload it.
function Get-Md5([string]$Path) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { ($md5.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $fs.Close(); $md5.Dispose() }
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
if ($PcPatchFile -and $BuildPcPatch) { Fail "use -PcPatchFile or -BuildPcPatch, not both" }

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
        # English name, ASCII: the PC installer names Play-in-<label>.cmd after it.
        label     = $(if ($entry.PSObject.Properties['label']) { $entry.label } else { $Locale })
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
        if (-not $XzJar) {
            $XzJar = Get-ChildItem -Path (Join-Path $env:USERPROFILE '.gradle\caches\modules-2\files-2.1\org.tukaani\xz') `
                -Recurse -Filter 'xz-*.jar' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch 'sources|javadoc' } | Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $XzJar) { Fail "xz jar not found; build the app once with Gradle or pass -XzJar" }
        $cp = "$Lz4Jar;$XzJar"

        $classes = Join-Path $OutDir 'autopatcher-classes'
        if (Test-Path -LiteralPath $classes) { Remove-Item -LiteralPath $classes -Recurse -Force }
        New-Item -ItemType Directory -Path $classes | Out-Null
        $core = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'app\src\main\java\com\mtpatch\enapply\core') -Filter *.java |
            ForEach-Object { $_.FullName }
        & javac -nowarn -encoding UTF-8 -d $classes -cp $cp @core
        if ($LASTEXITCODE -ne 0) { Fail "javac failed" }
        $tables = Join-Path $repoRoot 'app\src\main\assets\tables.txt'
        & java -cp "$classes;$cp" com.mtpatch.enapply.core.AutoPatchMain `
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
    if ($BuildPcPatch) {
        $en = $version.pc.language_ja_en
        $enBundle = Join-Path $OutDir 'language-ja_en.bundle'
        if (-not (Test-Path -LiteralPath $enBundle) -or (Get-Md5 $enBundle) -ne $en.md5) {
            Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/language-ja_en.bundle" -OutFile $enBundle
        }
        if ((Get-Md5 $enBundle) -ne $en.md5) { Fail "language-ja_en.bundle on the release doesn't match version.json's md5" }
        $enCache = Join-Path $OutDir 'translation_cache.en.json'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Build-TranslationCache.ps1') `
            -Locale $default -Out $enCache
        if ($LASTEXITCODE -ne 0) { Fail "cache build failed for '$default'" }
        $PcPatchFile = Join-Path $OutDir "built-language-ja_$Locale.bundle"
        $pyArgs = @('-X', 'utf8', (Join-Path $repoRoot 'tools\prefab-patch\build_locale_bundle.py'),
                    '--language-bundle', $enBundle, '--en-cache', $enCache, '--locale-cache', $cachePath,
                    '--out', $PcPatchFile)
        if ($PcMetadata) { $pyArgs += @('--metadata', $PcMetadata) }
        & python @pyArgs
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $PcPatchFile)) { Fail "build_locale_bundle.py failed" }
    }
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

    # --- 2c. optional PC asset builds (UI prefabs + images, in-app) -----------
    if (($PcPrefabDir -or $PcInappBuild) -and -not $block.Contains('pc')) {
        Fail "-PcPrefabDir / -PcInappBuild need the PC language bundle too (-BuildPcPatch or -PcPatchFile)"
    }
    if ($PcPrefabDir) {
        if (-not (Test-Path -LiteralPath (Join-Path $PcPrefabDir 'manifest.json'))) { Fail "no manifest.json in $PcPrefabDir" }
        . (Join-Path $repoRoot 'tools\pc\maintainer\PrefabZips.ps1')
        $zips = New-PrefabZips -PrefabDir $PcPrefabDir -OutDir $OutDir -TextZipName "prefab-patch-$Locale.zip" `
                               -ImageZipName "prefab-images-$Locale.zip" -Hash $version.pc.language_ja_en.hash
        foreach ($k in $zips.Keys) {
            $block.pc[$k] = $zips[$k]
            $upload += (Join-Path $OutDir $zips[$k].file)
        }
        # The text bundles must be built from the same stock files as English's,
        # or the installer skips them all as "changed by a game update".
        $enPrefab = $version.pc.PSObject.Properties['prefab_patch']
        if ($enPrefab -and [int]$zips.prefab_patch.bundles -lt [int]$enPrefab.Value.bundles) {
            Write-Host "NOTE: $($zips.prefab_patch.bundles) text bundles, English has $($enPrefab.Value.bundles): check the prefab map covers every string."
        }
    }
    if ($PcInappBuild) {
        $inappJson = "$PcInappBuild.json"
        foreach ($f in @($PcInappBuild, $inappJson)) { if (-not (Test-Path -LiteralPath $f)) { Fail "missing in-app build: $f" } }
        $meta = Get-Content -LiteralPath $inappJson -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $meta.stock_md5) { Fail "$inappJson has no stock_md5; rebuild with build_inapp.py" }
        $enInapp = $version.pc.PSObject.Properties['inapp_assets_all_en']
        if ($enInapp -and $meta.stock_md5 -ne $enInapp.Value.stock_md5 -and -not $Force) {
            Fail "in-app build targets stock $($meta.stock_md5), the release targets $($enInapp.Value.stock_md5): built for another game build (-Force overrides)"
        }
        $inappName = "inapp_assets_all_$Locale.bundle"
        $inappPath = Join-Path $OutDir $inappName
        Copy-Item -LiteralPath $PcInappBuild -Destination $inappPath -Force
        $inappMd5 = Get-Md5 $inappPath
        if ($meta.md5 -and $meta.md5 -ne $inappMd5) { Fail "$PcInappBuild does not match the md5 in its .json" }
        $block.pc.inapp = [ordered]@{
            file       = $inappName
            size       = (Get-Item -LiteralPath $inappPath).Length
            md5        = $inappMd5
            stock_md5  = $meta.stock_md5
            stock_size = $meta.stock_size
            crc        = $meta.crc
            hash       = $version.pc.language_ja_en.hash
        }
        $upload += $inappPath
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
        if ($p.Value.PSObject.Properties['pc']) {
            # This run's block is a dictionary; the others come from version.json.
            $pcv = $p.Value.pc
            $keys = if ($pcv -is [System.Collections.IDictionary]) { $pcv.Keys } else { $pcv.PSObject.Properties.Name }
            $parts = @($keys | Where-Object { $_ -ne 'language' })
            $mode += ' + PC' + $(if ($parts) { " ($($parts -join ', '))" } else { '' })
        }
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

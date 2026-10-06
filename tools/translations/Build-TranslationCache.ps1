<#
.SYNOPSIS
  Merge one locale's editable translation sources into the compact translation_cache.json.

.DESCRIPTION
  Sources live under translations/<locale>/:
    source/*.json  - the JP -> value "cache" map, one entry per line, keys sorted
    hand/*.json    - the ID-keyed "hand" tables (e_ui_text, e_day_of_week)

  The locale named "default" in translations/locales.json (English) is the CANONICAL
  key set. A non-default locale may be SPARSE: it carries only the entries that differ
  from English. Those entries are overlaid on the canonical map, so the emitted cache
  is always complete - an untranslated key falls back to English. A locale may not
  introduce a cache key, a hand table, or a hand id that English does not already
  have; that fails loudly rather than shipping a key nothing can match.

  Output is deterministic: all keys ordinal-sorted, no whitespace, UTF-8, real
  (unescaped) Japanese. The released cache is insertion-ordered, so a rebuilt file
  will NOT byte-match it; what CI checks is SEMANTIC equality (same keys mapping to
  the same values, same hand tables) via -Baseline.

  Fails loudly on duplicate keys across source files (a merge would silently drop
  one), on malformed JSON, and on a non-default locale inventing keys.

.EXAMPLE
  # rebuild the default locale into %TEMP% for inspection
  powershell -File tools\translations\Build-TranslationCache.ps1

.EXAMPLE
  # rebuild a locale and validate it against its released artifact (CI mode)
  powershell -File tools\translations\Build-TranslationCache.ps1 -Locale en -Baseline path\to\translation_cache.json
#>
param(
    [string]$TranslationsRoot = (Join-Path $PSScriptRoot '..\..\translations'),
    [string]$Locale,
    [string]$Out,
    [string]$Baseline
)

$ErrorActionPreference = 'Stop'

# --- locale registry ----------------------------------------------------------
$localesPath = Join-Path $TranslationsRoot 'locales.json'
if (-not (Test-Path -LiteralPath $localesPath)) { throw "missing locale registry: $localesPath" }
$registry = Get-Content -LiteralPath $localesPath -Raw | ConvertFrom-Json
$defaultLocale = $registry.default
if (-not $defaultLocale) { throw "locales.json has no 'default'" }
$known = @($registry.locales.PSObject.Properties.Name)
if (-not $Locale) { $Locale = $defaultLocale }
if ($known -notcontains $Locale) { throw "unknown locale '$Locale' (known: $($known -join ', '))" }

# Release artifact name: the default locale keeps the historic unsuffixed name.
function Get-CacheArtifactName([string]$Code) {
    if ($Code -eq $defaultLocale) { return 'translation_cache.json' }
    return "translation_cache.$Code.json"
}
if (-not $Out) { $Out = Join-Path $env:TEMP (Get-CacheArtifactName $Locale) }

function Read-Map([string]$Path) {
    # ConvertFrom-Json preserves insertion order on PSCustomObject via .PSObject.Properties.
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $obj = $raw | ConvertFrom-Json
    $map = [ordered]@{}
    foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
    return $map
}

# Read one locale's maps. A locale with no source directory is valid and empty.
function Read-LocaleMaps([string]$Root, [string]$Code) {
    $srcDir = Join-Path $Root (Join-Path $Code 'source')
    $handDir = Join-Path $Root (Join-Path $Code 'hand')

    $cache = [ordered]@{}
    $dupes = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $srcDir) {
        Get-ChildItem -LiteralPath $srcDir -Filter *.json | Sort-Object Name | ForEach-Object {
            $m = Read-Map $_.FullName
            foreach ($k in $m.Keys) {
                if ($cache.Contains($k)) { $dupes.Add("$k  (in $($_.Name))") }
                else { $cache[$k] = $m[$k] }
            }
        }
    }
    if ($dupes.Count) {
        Write-Host "ERROR: duplicate Japanese keys across source files for locale '$Code' (fix before merging):"
        $dupes | ForEach-Object { Write-Host "  $_" }
        exit 1
    }

    $hand = [ordered]@{}
    if (Test-Path -LiteralPath $handDir) {
        Get-ChildItem -LiteralPath $handDir -Filter *.json | Sort-Object Name | ForEach-Object {
            $hand[$_.BaseName] = Read-Map $_.FullName
        }
    }

    return [pscustomobject]@{ Cache = $cache; Hand = $hand }
}

# Overlay a sparse locale on the canonical map. Returns the number of entries that
# actually differ (the translation coverage). Mutates $Canonical in place.
function Merge-Overlay($Canonical, $Overlay, [string]$Code) {
    $changed = 0
    foreach ($k in $Overlay.Cache.Keys) {
        if (-not $Canonical.Cache.Contains($k)) {
            Write-Host "ERROR: locale '$Code' has a cache key '$defaultLocale' does not have: $k"
            exit 1
        }
        if ($Canonical.Cache[$k] -ne $Overlay.Cache[$k]) { $changed++ }
        $Canonical.Cache[$k] = $Overlay.Cache[$k]
    }
    foreach ($t in $Overlay.Hand.Keys) {
        if (-not $Canonical.Hand.Contains($t)) {
            Write-Host "ERROR: locale '$Code' has a hand table '$defaultLocale' does not have: $t"
            exit 1
        }
        foreach ($id in $Overlay.Hand[$t].Keys) {
            if (-not $Canonical.Hand[$t].Contains($id)) {
                Write-Host "ERROR: locale '$Code' has hand[$t] id '$defaultLocale' does not have: $id"
                exit 1
            }
            if ($Canonical.Hand[$t][$id] -ne $Overlay.Hand[$t][$id]) { $changed++ }
            $Canonical.Hand[$t][$id] = $Overlay.Hand[$t][$id]
        }
    }
    return $changed
}

# --- canonical map + locale overlay -------------------------------------------
$canonical = Read-LocaleMaps $TranslationsRoot $defaultLocale
if ($canonical.Cache.Count -eq 0) {
    throw "no '$defaultLocale' entries under $TranslationsRoot\$defaultLocale\source - nothing to anchor the cache to."
}

if ($Locale -ne $defaultLocale) {
    $overlay = Read-LocaleMaps $TranslationsRoot $Locale
    $changed = Merge-Overlay $canonical $overlay $Locale
    $pct = [math]::Round(100.0 * $changed / $canonical.Cache.Count, 1)
    Write-Host "locale '$Locale': $changed / $($canonical.Cache.Count) entries differ from '$defaultLocale' ($pct%)"
}

# --- emit compact, sorted, UTF-8, unescaped-Japanese ---------------------------
# Sort all keys for determinism. Use ORDINAL (code-point) sorting, matching the
# original cache (produced by Python's default sort). Culture-aware sorting
# would order fullwidth punctuation differently and break the byte-match.
# ([Array]::Sort with an ordinal StringComparer works on both PS5.1 and PS7;
# Sort-Object's -Comparer is PS7-only.)
function Sort-Ordinal([string[]]$Keys) {
    $arr = $Keys.Clone()
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return $arr
}
$sortedCache = [ordered]@{}
foreach ($k in (Sort-Ordinal @($canonical.Cache.Keys))) { $sortedCache[$k] = $canonical.Cache[$k] }
$sortedHand = [ordered]@{}
foreach ($t in (Sort-Ordinal @($canonical.Hand.Keys))) {
    $tbl = [ordered]@{}
    foreach ($k in (Sort-Ordinal @($canonical.Hand[$t].Keys))) { $tbl[$k] = $canonical.Hand[$t][$k] }
    $sortedHand[$t] = $tbl
}
$result = [ordered]@{ cache = $sortedCache; hand = $sortedHand }

# ConvertTo-Json escapes non-ASCII as \uXXXX; the original uses literal UTF-8.
# So serialize then unescape \uXXXX sequences back to real characters.
$json = $result | ConvertTo-Json -Depth 6 -Compress
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', { param($m) [char][int]("0x" + $m.Groups[1].Value) })

[IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "wrote $Out  ($((Get-Item $Out).Length) B; locale=$Locale cache=$($sortedCache.Count) hand-tables=$($sortedHand.Count))"

# --- optional semantic check against baseline ---------------------------------
# The release cache is insertion-ordered; the rebuild is sorted, so a byte compare
# can never pass. What CI must guarantee is SEMANTIC equality: the same keys mapping
# to the same values (plus the same hand tables). That comparison lives in
# _verify_translation_cache_impl.py (same Python the splitter already needs).
if ($Baseline) {
    $verifier = Join-Path $PSScriptRoot '_verify_translation_cache_impl.py'
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    python $verifier --rebuilt $Out --baseline $Baseline
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    exit $code
}

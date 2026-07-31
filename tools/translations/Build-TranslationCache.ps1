<#
.SYNOPSIS
  Merge the editable translation sources back into the compact translation_cache.json.

.DESCRIPTION
  Reads every translations/source/*.json (the JP->EN cache) and
  translations/hand/*.json (the ID-keyed hand tables) and re-emits the single
  compact translation_cache.json that the patch consumes.

  Output is deterministic: all keys ordinal-sorted, no whitespace, UTF-8, real
  (unescaped) Japanese. The released cache is insertion-ordered, so a rebuilt
  file will NOT byte-match it; what CI checks is SEMANTIC equality (same JP keys
  mapping to the same EN values, same hand tables) via -Baseline.

  Fails loudly on duplicate JP keys across source files (a merge would silently
  drop one) and on malformed JSON.

.EXAMPLE
  # rebuild into %TEMP% for inspection
  powershell -File tools\translations\Build-TranslationCache.ps1 -Out $env:TEMP\translation_cache.json

.EXAMPLE
  # rebuild + validate it matches the committed sources (CI mode)
  powershell -File tools\translations\Build-TranslationCache.ps1 -Check -Baseline path\to\translation_cache.json
#>
param(
    [string]$TranslationsRoot = (Join-Path $PSScriptRoot '..\..\translations'),
    [string]$Out = (Join-Path $env:TEMP 'translation_cache.json'),
    # With -Check, compare the rebuilt cache against this baseline and exit 1 on mismatch.
    [string]$Baseline
)

$ErrorActionPreference = 'Stop'

function Read-Map([string]$Path) {
    # ConvertFrom-Json preserves insertion order on PSCustomObject via .PSObject.Properties.
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $obj = $raw | ConvertFrom-Json
    $map = [ordered]@{}
    foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
    return $map
}

# --- merge sources ------------------------------------------------------------
$cache = [ordered]@{}
$dupes = New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath (Join-Path $TranslationsRoot 'source') -Filter *.json | Sort-Object Name | ForEach-Object {
    $m = Read-Map $_.FullName
    foreach ($k in $m.Keys) {
        if ($cache.Contains($k)) { $dupes.Add("$k  (in $($_.Name))") }
        else { $cache[$k] = $m[$k] }
    }
}
if ($dupes.Count) {
    Write-Host "ERROR: duplicate Japanese keys across source files (fix before merging):"
    $dupes | ForEach-Object { Write-Host "  $_" }
    exit 1
}

$hand = [ordered]@{}
Get-ChildItem -LiteralPath (Join-Path $TranslationsRoot 'hand') -Filter *.json | Sort-Object Name | ForEach-Object {
    $hand[$_.BaseName] = Read-Map $_.FullName
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
foreach ($k in (Sort-Ordinal @($cache.Keys))) { $sortedCache[$k] = $cache[$k] }
$sortedHand = [ordered]@{}
foreach ($t in (Sort-Ordinal @($hand.Keys))) {
    $tbl = [ordered]@{}
    foreach ($k in (Sort-Ordinal @($hand[$t].Keys))) { $tbl[$k] = $hand[$t][$k] }
    $sortedHand[$t] = $tbl
}
$result = [ordered]@{ cache = $sortedCache; hand = $sortedHand }

# ConvertTo-Json escapes non-ASCII as \uXXXX; the original uses literal UTF-8.
# So serialize then unescape \uXXXX sequences back to real characters.
$json = $result | ConvertTo-Json -Depth 6 -Compress
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', { param($m) [char][int]("0x" + $m.Groups[1].Value) })

[IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "wrote $Out  ($((Get-Item $Out).Length) B; cache=$($sortedCache.Count) hand-tables=$($sortedHand.Count))"

# --- optional semantic check against baseline ---------------------------------
# The original release cache is insertion-ordered; the rebuild is sorted, so a
# byte compare can never pass. What CI must guarantee is SEMANTIC equality: the
# same JP keys mapping to the same EN values (plus the same hand tables). That
# comparison lives in _verify_translation_cache_impl.py (same Python the
# splitter already needs).
if ($Baseline) {
    $verifier = Join-Path $PSScriptRoot '_verify_translation_cache_impl.py'
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    python $verifier --rebuilt $Out --baseline $Baseline
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    exit $code
}

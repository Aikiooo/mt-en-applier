<#
.SYNOPSIS
  Split the monolithic translation_cache.json into human-editable themed source files.

.DESCRIPTION
  One-time / re-runnable generator. Reads the compact patch-latest
  translation_cache.json and writes:

    translations/source/<theme>.json   - the big JP->EN "cache" map, grouped by
                                         theme, ONE entry per line, keys sorted.
    translations/hand/<table>.json     - the ID-keyed "hand" tables (e_ui_text,
                                         e_day_of_week), one entry per line.

  One-entry-per-line is the whole point: a PR that changes a single translation
  shows a single-line diff instead of a 2 MB blob.

  The split is LOSSLESS: Build-TranslationCache.ps1 re-merges these files into a
  byte-identical cache (keys are sorted everywhere, so order is deterministic).

.EXAMPLE
  python tools/translations/split_translation_cache.py -Cache path\to\translation_cache.json
#>
param(
    [string]$Cache = (Join-Path $env:TEMP 'mt-tcache\tc.json'),
    [string]$OutRoot = (Join-Path $PSScriptRoot '..\..\translations')
)

$ErrorActionPreference = 'Stop'
$py = Join-Path $PSScriptRoot '_split_translation_cache_impl.py'
if (-not (Test-Path $py)) { throw "missing helper: $py" }
python $py --cache $Cache --out $OutRoot

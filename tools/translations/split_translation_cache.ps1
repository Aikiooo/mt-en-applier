<#
.SYNOPSIS
  Split a built translation_cache.json back into human-editable, themed source files.

.DESCRIPTION
  Re-runnable generator. Reads a compact translation_cache.json and writes into the
  locale's folder under translations/:

    <locale>/source/<theme>.json  - the JP -> value map, grouped by theme, ONE entry
                                    per line, keys sorted.
    <locale>/hand/<table>.json    - the ID-keyed hand tables, one entry per line.

  One-entry-per-line is the whole point: a PR that changes a single translation shows
  a single-line diff instead of a 2 MB blob.

  The default locale (English) is split in FULL and is lossless.

  A non-default locale is SPARSE: pass -Canonical (the built default-locale cache) and
  only the entries whose value differs from it are written, so regenerating does not
  re-inflate English back into the locale's files.

.EXAMPLE
  powershell -File tools\translations\split_translation_cache.ps1 -Cache path\to\translation_cache.json

.EXAMPLE
  # refresh a sparse locale against the current English cache
  powershell -File tools\translations\split_translation_cache.ps1 -Cache tc.es.json -Locale es -Canonical tc.en.json
#>
param(
    [Parameter(Mandatory)][string]$Cache,
    [string]$Locale,
    [string]$Canonical,
    [string]$OutRoot = (Join-Path $PSScriptRoot '..\..\translations')
)

$ErrorActionPreference = 'Stop'

$localesPath = Join-Path $OutRoot 'locales.json'
if (-not (Test-Path -LiteralPath $localesPath)) { throw "missing locale registry: $localesPath" }
$registry = Get-Content -LiteralPath $localesPath -Raw | ConvertFrom-Json
$defaultLocale = $registry.default
if (-not $Locale) { $Locale = $defaultLocale }
$known = @($registry.locales.PSObject.Properties.Name)
if ($known -notcontains $Locale) { throw "unknown locale '$Locale' (known: $($known -join ', '))" }

if ($Locale -ne $defaultLocale -and -not $Canonical) {
    throw "locale '$Locale' is sparse: pass -Canonical (the built '$defaultLocale' cache) so only differing entries are written."
}
if ($Locale -eq $defaultLocale -and $Canonical) {
    Write-Host "note: -Canonical is ignored for the default locale '$defaultLocale' (full split)."
}

$py = Join-Path $PSScriptRoot '_split_translation_cache_impl.py'
if (-not (Test-Path $py)) { throw "missing helper: $py" }

$pyArgs = @($py, '--cache', $Cache, '--out', $OutRoot, '--locale', $Locale)
if ($Canonical) { $pyArgs += @('--canonical', $Canonical) }
python @pyArgs

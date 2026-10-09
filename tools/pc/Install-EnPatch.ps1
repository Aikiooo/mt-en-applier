<#
.SYNOPSIS
  One-command installer for the Mushoku Tensei PC translation patch (DMM client).

.DESCRIPTION
  - Downloads the latest patch for the chosen language from the rolling
    'patch-latest' GitHub release and verifies size + md5.
  - Seeds the exact-size, CRC-forged language bundle into the Unity
    Addressables cache (__data). The catalog is left untouched; editing the
    catalog is what triggers the "Failed to acquire resources" integrity error.
  - Captures clean stock copies (inapp bundle + boot.config) so DMM file
    repairs stay reversible and a future launcher can satisfy the file check.

  Languages: only the ones published for the current game build are offered.
  With one (English) there is no prompt; with several, a short menu appears
  (default: last choice, else the Windows display language, else English) and
  the choice is remembered for the next run. -Language skips the menu.

  Run this once. After that, just click Play in DMM GAME PLAYER.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -GameDir 'D:\Games\mushoku_coe_cl' -Force
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -Language es
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -Check     # report only, change nothing
  powershell -ExecutionPolicy Bypass -File Install-EnPatch.ps1 -Restore   # back to Japanese
#>
param(
    [string]$GameDir,
    [switch]$Force,
    # Patch language code (en, es, ...); skips the menu.
    [string]$Language,
    # Report what an install would do (game, cache, current language), change nothing.
    [switch]$Check,
    # Remove the patched language pack so the game re-downloads Japanese.
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'MT.EnPatch.psm1') -Force

Write-Host 'MT-EN PC installer'

# --- restore: no game folder or download needed -------------------------------
if ($Restore) {
    $cacheDir = Get-LangCacheDir
    $data = if ($cacheDir) { Join-Path $cacheDir '__data' }
    if (-not $data -or -not (Test-Path -LiteralPath $data)) {
        Write-Host 'No language pack in the game cache - nothing to restore.'
        exit 0
    }
    if (Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue) {
        Write-Host 'Close the game first, then run this again.'
        exit 1
    }
    Remove-Item -LiteralPath $data -Force
    $info = Join-Path $cacheDir '__info'
    if (Test-Path -LiteralPath $info) { Remove-Item -LiteralPath $info -Force }
    Write-Host 'Restored: the patched language pack was removed.'
    Write-Host 'Launch the game; it re-downloads the Japanese text on the title screen.'
    exit 0
}

# --- 1. locate the game -----------------------------------------------------
$gameDir = Get-GameDir -Override $GameDir
if (-not $gameDir) {
    Write-Host @"
Could not find the game automatically.
Pass its folder explicitly, e.g.:
  Install-EnPatch.ps1 -GameDir 'D:\Games\mushoku_coe_cl'
(The folder must contain $($GameExeName).)
"@
    exit 1
}
Write-Host "game dir : $gameDir"

$liveInapp = Join-Path $gameDir $InappRelPath
$liveBoot  = Join-Path $gameDir $BootCfgRelPath
foreach ($f in @($liveInapp, $liveBoot)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "ERROR: expected game file missing: $f"; exit 1 }
}

# --- 2. release info + language ----------------------------------------------
if ($Check) {
    # Read-only: version.json is kept in memory, nothing is written. Decoded as
    # UTF-8 explicitly: 5.1 assumes Latin-1 when the server sends no charset
    # (GitHub release assets don't), which would garble non-ASCII language names.
    $raw = (Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBase/$VersionFile").RawContentStream.ToArray()
    $version = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
} else {
    $version = Get-ReleaseInfo
}
$langs = @(Get-PcLanguages -Version $version)
$settingsPath = Join-Path $PatchDataDir 'settings.json'

function Read-SavedLanguage {
    try {
        if (Test-Path -LiteralPath $settingsPath) {
            return (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).language
        }
    } catch { }
    return $null
}

if ($Language) {
    $chosen = $langs | Where-Object { $_.Code -eq $Language } | Select-Object -First 1
    if (-not $chosen) {
        Write-Host "Language '$Language' isn't published for this game version. Available: $(($langs | ForEach-Object { $_.Code }) -join ', ')"
        exit 1
    }
} elseif ($langs.Count -eq 1) {
    $chosen = $langs[0]
} else {
    $saved = Read-SavedLanguage
    $osLang = (Get-UICulture).TwoLetterISOLanguageName
    $default = $langs | Where-Object { $_.Code -eq $saved } | Select-Object -First 1
    $from = 'last time'
    if (-not $default) { $default = $langs | Where-Object { $_.Code -eq $osLang } | Select-Object -First 1; $from = 'Windows language' }
    if (-not $default) { $default = $langs[0]; $from = 'default' }
    $chosen = $default
    $canAsk = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    if ($Check) {
        Write-Host "languages    : $(($langs | ForEach-Object { $_.Name }) -join ', ') (would default to $($default.Name))"
    } elseif ($saved -and $default.Code -eq $saved) {
        Write-Host "language : $($chosen.Name) (from last time; pass -Language <code> to change)"
    } elseif ($canAsk) {
        Write-Host ''
        Write-Host 'Patch language:'
        for ($i = 0; $i -lt $langs.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $langs[$i].Name) }
        $defIdx = [array]::IndexOf(@($langs | ForEach-Object { $_.Code }), $default.Code) + 1
        $ans = Read-Host "Choose [$defIdx]"
        if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $langs.Count) { $chosen = $langs[[int]$ans - 1] }
    } else {
        Write-Host "language : $($chosen.Name) ($from)"
    }
}

# --- 3. check mode -------------------------------------------------------------
if ($Check) {
    $want = $chosen.Want
    Write-Host "latest patch : $($chosen.Name), $($want.size) B, md5 $($want.md5.Substring(0,8))..., game build $($version.game_version)"
    $cacheDir = Get-LangCacheDir
    $live = if ($cacheDir) { Join-Path $cacheDir '__data' }
    if (-not $cacheDir) {
        Write-Host 'cache        : not found - launch the game once to the title screen first'
    } elseif (-not (Test-Path -LiteralPath $live)) {
        Write-Host "cache        : $cacheDir (no language pack yet)"
    } else {
        $liveMd5 = Get-Md5 $live
        $hit = $langs | Where-Object { $_.Want.md5 -eq $liveMd5 } | Select-Object -First 1
        $state = if ($hit) { "$($hit.Name) (latest patch)" } else { 'Japanese, or an older patch' }
        Write-Host "cache        : $cacheDir"
        Write-Host "installed    : $state"
    }
    if ($cacheDir -and $version.pc.language_ja_en.hash -and (Split-Path $cacheDir -Leaf) -ne $version.pc.language_ja_en.hash) {
        Write-Host 'NOTE: the game has not downloaded the language pack this patch targets yet.'
        Write-Host '      Launch it once to the title screen, close it, then install.'
    }
    Write-Host 'check only - nothing was changed.'
    exit 0
}

# Seeding a folder the game no longer (or doesn't yet) use would silently do nothing.
$cacheDir = Get-LangCacheDir
$target = $version.pc.language_ja_en.hash
if ($cacheDir -and $target -and (Split-Path $cacheDir -Leaf) -ne $target -and -not $Force) {
    Write-Host @"
The game's language pack doesn't match this patch's game version yet.
Launch the game once to the title screen (so it downloads its update), close it,
then run this again. (If the game is already up to date, the patch for the new
version isn't out yet. -Force installs anyway.)
"@
    exit 1
}

try { @{ language = $chosen.Code } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding ASCII } catch { }

# --- 4. download + verify the patch -----------------------------------------
Write-Host "fetching the $($chosen.Name) patch from the patch-latest release ..."
$art = Get-PatchArtifacts -Version $version -Language $chosen -Force:$Force
$langBundle = $art.Files.lang
Write-Host "  language bundle : $(Split-Path $langBundle -Leaf)  ($((Get-Item $langBundle).Length) B, md5 $((Get-Md5 $langBundle).Substring(0,8))...)"

# --- 5. stock backups (so DMM repairs are reversible; kept for a future launcher) ----
# Keep clean stock copies so a file check / repair can be satisfied, then re-seeded.
$stockInapp = Join-Path $PatchDataDir 'stock_inapp_assets_all.bundle'
$stockBoot  = Join-Path $PatchDataDir 'stock_boot.config'

# If the live inapp is currently stock (not our EN patch), snapshot it as stock.
# Only the patch's md5 is needed for that, so the 63 MB patch isn't downloaded.
$liveMd5  = Get-Md5 $liveInapp
$patchMd5 = $art.Want.inapp.md5
if ($liveMd5 -ne $patchMd5) {
    Copy-Item -LiteralPath $liveInapp -Destination $stockInapp -Force
    Write-Host 'stock inapp snapshot saved'
} elseif (-not (Test-Path $stockInapp)) {
    Write-Host @"
NOTE: the live inapp bundle is already the EN patch and no stock snapshot exists.
Open DMM GAME PLAYER and let it verify/repair the game files once (or reinstall),
then re-run this installer so a clean stock copy can be captured.
"@
}
Copy-Item -LiteralPath $liveBoot -Destination $stockBoot -Force

# A logging-enabled boot.config (drops the nolog line) so Player.log is written.
$bootLog = Join-Path $PatchDataDir 'boot_logging.config'
Get-Content -LiteralPath $liveBoot | Where-Object { $_ -notmatch '^nolog=' } | Set-Content -LiteralPath $bootLog

# --- 6. seed the language cache ----------------------------------------------
Write-Host "seeding the $($chosen.Name) language bundle into the Unity cache ..."
$res = Install-LanguageCache -LangBundlePath $langBundle -ExpectedSize ([int64]$art.Want.lang.size)
Write-Host "  cache : $($res.CacheDir)"
Write-Host "  __data md5 $($res.DataMd5.Substring(0,8))...  size-ok=$($res.SizeOk)"

if (-not $res.SizeOk) {
    Write-Host "WARNING: seeded __data is not the expected $($art.Want.lang.size) bytes."
}

Write-Host ''
Write-Host "Install complete. To play in $($chosen.Name):"
Write-Host '  click Play in DMM GAME PLAYER (no launcher needed)'
Write-Host '(The language bundle is seeded into the game cache and stays until the game updates.)'
Write-Host 'Back to Japanese any time: run this installer with -Restore.'

# MT.EnPatch.psm1 - self-contained helpers + constants for the PC English patch.
# Import-Module this file; no dot-sourcing of config.ps1 required.

Set-StrictMode -Version Latest

# Windows PowerShell 5.1 can default to TLS 1.0; GitHub needs 1.2. Set here as
# well as in install.ps1: every download this module makes runs in the child
# process the one-liner spawns, which does not inherit the parent's setting.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- constants (module scope) -------------------------------------------------
$script:Repo          = 'Aikiooo/mt-en-applier'
$script:Release       = 'patch-latest'
$script:ReleaseBase   = "https://github.com/$($script:Repo)/releases/download/$($script:Release)"
if ($env:MT_EN_RELEASE_BASE) { $script:ReleaseBase = $env:MT_EN_RELEASE_BASE.TrimEnd('/') }   # testing only

$script:LangFileName  = 'language-ja_en.bundle'      # exact-size, CRC-forged language bundle
$script:InappFileName = 'inapp_assets_all_en.bundle'  # EN inapp asset patch (StreamingAssets, swapped per session)
$script:InappMetaName = 'inapp_assets_all_en.bundle.json'  # stock_md5/md5 the swap watcher verifies
$script:PrefabZipName = 'prefab-patch.zip'             # the English UI-prefab bundles, one zip per game build
$script:PrefabImagesZipName = 'prefab-images.zip'      # the image-only bundles, downloaded only if the player wants them
$script:VersionFile   = 'version.json'

$script:GameProcessName = 'mushoku_coe_cl'
$script:GameExeName     = 'mushoku_coe_cl.exe'
$script:InappRelPath    = 'mushoku_coe_cl_Data\StreamingAssets\aa\StandaloneWindows64\inapp_assets_all.bundle'
$script:BootCfgRelPath  = 'mushoku_coe_cl_Data\boot.config'

# Unity Addressables cache of the language bundle. The path lives under the
# per-user "LocalLow" folder, which has no reliable env var on every Windows
# version, so candidate roots are globbed rather than built from $env:LOCALAPPDATA.
$script:LangBundleGuid = 'cad73e991807559422ab03e01424a9d3'
$script:LangBundleHash = '515508ac386204f43f28aea20ba4e470'
$script:LangBundleSize = 1898964
$script:PatchDataDir = Join-Path $env:LOCALAPPDATA 'MT-EN-Applier\pc'

# Resolve the non-ASCII Unity publisher cache dir ("GREE Entertainment_<クロエコ>")
# by searching the usual LocalLow locations. When several match, the one that
# holds the language bundle's own folder is the game's: taking the first one
# would seed the wrong cache.
function Get-UnityCachePublisherDir {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Low\Unity'),
        (Join-Path $env:USERPROFILE 'AppData\LocalLow\Unity'),
        (Join-Path (Split-Path $env:APPDATA -Parent) 'LocalLow\Unity')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    $pubs = @()
    foreach ($root in $candidates) {
        $pubs += @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -like 'GREE Entertainment*' })
    }
    $pubs = @($pubs | Select-Object -Unique)
    foreach ($p in $pubs) {
        if (Test-Path -LiteralPath (Join-Path $p.FullName $script:LangBundleGuid)) { return $p.FullName }
    }
    if ($pubs.Count) { return $pubs[0].FullName }
    return $null
}

function Get-Md5 {
    param([Parameter(Mandatory)][string]$Path)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { ($md5.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $fs.Close(); $md5.Dispose() }
}

# Live asset-hash for the language-bundle cache folder: read from version.json's
# pc block when available (Get-PatchArtifacts writes it), else the baked constant.
# Keeps fresh-install cache seeding correct across game updates without a psm1 bump.
function Get-LangBundleHash {
    try {
        $vp = Join-Path $script:PatchDataDir $script:VersionFile
        if (Test-Path -LiteralPath $vp) {
            $v = Get-Content -LiteralPath $vp -Raw | ConvertFrom-Json
            $h = $v.pc.language_ja_en.hash
            if ($h -and $h -match '^[0-9a-f]{32}$') { return $h }
        }
    } catch { }
    return $script:LangBundleHash
}

# Resolve the full language-bundle cache dir (…\GREE Entertainment_*\<guid>\<hash>).
# The asset-hash subfolder changes on some updates, so prefer the NEWEST hash
# folder the game has actually written (that is the one the catalog pins);
# fall back to the live hash (version.json or constant) only when no folder
# exists yet (fresh install: the installer creates it before the game runs).
function Get-LangCacheDir {
    $pub = Get-UnityCachePublisherDir
    if (-not $pub) { return $null }
    $guidDir = Join-Path $pub $script:LangBundleGuid
    $live = Get-ChildItem -LiteralPath $guidDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($live) { return $live.FullName }
    return (Join-Path $guidDir (Get-LangBundleHash))
}

# Read the game's install path from DMM GAME PLAYER's own config, which records
# every installed title: %APPDATA%\dmmgameplayer5\dmmgame.cnf ->
#   { "contents": [ { "productId": "mushoku_coe_cl", "detail": { "path": "..." } } ] }
# This is the authoritative source and works no matter where DMM put the game.
function Get-GameDirFromDmmConfig {
    $cnf = Join-Path $env:APPDATA 'dmmgameplayer5\dmmgame.cnf'
    if (-not (Test-Path -LiteralPath $cnf)) { return $null }
    try {
        $cfg = Get-Content -LiteralPath $cnf -Raw | ConvertFrom-Json
        foreach ($c in @($cfg.contents)) {
            if ($c.productId -ne $script:GameProcessName) { continue }
            $p = $null
            if ($c.detail -and $c.detail.PSObject.Properties['path']) { $p = $c.detail.path }
            if ($p -and (Test-Path -LiteralPath (Join-Path $p $script:GameExeName))) { return $p }
        }
    } catch { }  # malformed/locked config -> fall through to other detectors
    return $null
}

# Locate the game install root (the folder that contains mushoku_coe_cl.exe).
function Get-GameDir {
    param([string]$Override)
    if ($Override) {
        if (Test-Path (Join-Path $Override $script:GameExeName)) { return $Override }
        throw "Game exe not found under -GameDir '$Override'."
    }
    # 1) DMM's own config (authoritative, any install location).
    $fromCfg = Get-GameDirFromDmmConfig
    if ($fromCfg) { return $fromCfg }
    # 2) A running game process.
    $proc = Get-Process -Name $script:GameProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) { return (Split-Path $proc.Path -Parent) }
    # 3) Last resort: glob fixed drives (depth-limited) for the exe. Uses cmd's
    #    fast built-in dir scan; silent on access-denied/unready drives.
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Za-z]:\\$' }
    foreach ($d in $drives) {
        $hit = cmd /c "dir /b /s /a:-d `"$($d.Root)$($script:GameExeName)`" 2>nul" | Select-Object -First 1
        if ($hit) { return (Split-Path $hit -Parent) }
    }
    return $null
}

# Fetch version.json from the rolling release (saved in PatchDataDir, which
# Get-LangBundleHash reads) and return it as an object.
function Get-ReleaseInfo {
    New-Item -ItemType Directory -Force -Path $script:PatchDataDir | Out-Null
    $versionPath = Join-Path $script:PatchDataDir $script:VersionFile
    Invoke-WebRequest -UseBasicParsing -Uri "$($script:ReleaseBase)/$($script:VersionFile)" -OutFile $versionPath
    $version = Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $version.PSObject.Properties['pc']) {
        throw 'version.json on the release has no "pc" block yet. Publish the PC build first (maintainer\Publish-PcPatch.ps1).'
    }
    return $version
}

# Optional JSON field (StrictMode-safe): $null when absent.
function Get-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# PC patch languages published on the release: English (the historic top-level
# "pc" block) first, then every "locales.<code>.pc.language" entry built for the
# SAME game build (its asset hash matches English's); a stale one is not offered.
# Each item: @{ Code; Name; File; Want = @{ size; md5; hash } }.
function Get-PcLanguages {
    param([Parameter(Mandatory)]$Version)
    $en = $Version.pc.language_ja_en
    $out = @([pscustomobject]@{ Code = 'en'; Name = 'English'; File = $script:LangFileName; Want = $en })
    $locs = Get-Prop $Version 'locales'
    if (-not $locs) { return $out }
    $enHash = Get-Prop $en 'hash'
    foreach ($p in $locs.PSObject.Properties) {
        $code = $p.Name
        if ($code -eq 'en' -or $code -notmatch '^[A-Za-z0-9_-]{1,16}$') { continue }
        $w = Get-Prop (Get-Prop $p.Value 'pc') 'language'
        if (-not $w) { continue }
        $file = Get-Prop $w 'file'
        if (-not $file -or $file -notmatch '^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$') { continue }
        if (-not (Get-Prop $w 'md5') -or -not (Get-Prop $w 'size')) { continue }
        $hash = Get-Prop $w 'hash'
        if ($enHash -and $hash -and $hash -ne $enHash) { continue }   # built for another game build
        $name = Get-Prop $p.Value 'name'
        if (-not $name) { $name = $code }
        $out += [pscustomobject]@{ Code = $code; Name = $name; File = $file; Want = $w }
    }
    return $out
}

# Download one file from the release, resuming a partial download when there is
# one. curl.exe ships with Windows 10 1803+ and is the only resumable option in
# Windows PowerShell 5.1 - the in-app bundle is 61 MB and the prefab zips 41+23 MB,
# so a dropped connection must not restart them. Invoke-WebRequest is the
# fallback (no resume, and 5.1 throttles it badly unless progress is silenced).
function Get-RemoteFile {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Destination)
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        & $curl -L --fail --retry 3 --retry-delay 2 -C - -sS -o $Destination $Uri
        if ($LASTEXITCODE -eq 0) { return }
        Write-Host "  curl failed (exit $LASTEXITCODE); falling back to Invoke-WebRequest ..."
    }
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination }
    finally { $ProgressPreference = $prev }
}

# Download (if missing or changed) + verify one file from the release.
function Get-VerifiedFile {
    param([string]$Name, $Want, [switch]$Force)
    $dst = Join-Path $script:PatchDataDir $Name
    $part = "$dst.part"
    $need = $Force -or -not (Test-Path $dst) -or ((Get-Item $dst).Length -ne [int64]$Want.size) -or ((Get-Md5 $dst) -ne $Want.md5)
    if ($need) {
        # A complete file left by an older release can be shorter than this one,
        # and resuming onto it would append the new tail to the old bytes. Only
        # the .part file of an interrupted attempt for THIS expected md5 is ever
        # resumed: the sidecar records which download it belongs to.
        $partMd5 = "$part.md5"
        $resume = (Test-Path -LiteralPath $part) -and (Test-Path -LiteralPath $partMd5) -and
                  ((Get-Content -LiteralPath $partMd5 -Raw -ErrorAction SilentlyContinue).Trim() -eq $Want.md5) -and
                  ((Get-Item $part).Length -lt [int64]$Want.size)
        if (-not $resume) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            Set-Content -LiteralPath $partMd5 -Value $Want.md5 -Encoding ASCII
        }
        Write-Host "  $(if ($resume) { 'resuming' } else { 'downloading' }) $Name ($([math]::Round([int64]$Want.size / 1MB, 1)) MB) ..."
        Get-RemoteFile -Uri "$($script:ReleaseBase)/$Name" -Destination $part
        Move-Item -LiteralPath $part -Destination $dst -Force
        Remove-Item -LiteralPath $partMd5 -Force -ErrorAction SilentlyContinue
    }
    $actualSize = (Get-Item $dst).Length
    $actualMd5  = Get-Md5 $dst
    if ($actualSize -ne [int64]$Want.size -or $actualMd5 -ne $Want.md5) {
        # Drop it rather than leaving a file whose size matches but whose bytes
        # do not: the next run then downloads it again instead of failing.
        Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$dst.part" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$dst.part.md5" -Force -ErrorAction SilentlyContinue
        throw "Integrity check failed for ${Name}: size $actualSize/$($Want.size), md5 $actualMd5/$($Want.md5). Re-run the installer; it will download it again."
    }
    return $dst
}

# Download + verify the chosen language bundle, and optionally the asset patches
# (the 61 MB in-app bundle, and the prefab zip the installer unpacks itself).
# Everything is opted into by the caller so a plain language install fetches 1.9 MB.
function Get-PatchArtifacts {
    param([Parameter(Mandatory)]$Version, [Parameter(Mandatory)]$Language,
          [switch]$IncludeInapp, [switch]$IncludePrefabs, [switch]$Force)
    $files = @{ lang = Get-VerifiedFile -Name $Language.File -Want $Language.Want -Force:$Force }
    if ($IncludeInapp) {
        $files.inapp = Get-VerifiedFile -Name $script:InappFileName -Want $Version.pc.inapp_assets_all_en -Force:$Force
    }
    if ($IncludePrefabs) {
        $pp = Get-Prop (Get-Prop $Version 'pc') 'prefab_patch'
        if ($pp) { $files.prefab = Get-VerifiedFile -Name (Get-Prop $pp 'file') -Want $pp -Force:$Force }
    }
    return @{ Version = $Version; Files = $files; Want = @{ lang = $Language.Want; inapp = $Version.pc.inapp_assets_all_en
                                                            prefab = (Get-Prop (Get-Prop $Version 'pc') 'prefab_patch') } }
}

# Seed the exact-size language bundle into the Unity cache __data (catalog untouched).
function Install-LanguageCache {
    param(
        [Parameter(Mandatory)][string]$LangBundlePath,
        # Live expected size from version.json's pc block (caller passes it);
        # the constant is only a fallback so size changes never need a psm1 bump.
        [int64]$ExpectedSize = $script:LangBundleSize
    )
    $cacheDir = Get-LangCacheDir
    if (-not $cacheDir) {
        $pub = Get-UnityCachePublisherDir
        if (-not $pub) { throw 'Unity cache publisher folder not found. Launch the game once to the title screen, then retry.' }
        $cacheDir = Join-Path $pub (Join-Path $script:LangBundleGuid (Get-LangBundleHash))
    }
    # Get-LangCacheDir returns the folder the game *would* use when the cache has
    # no language pack yet (fresh install, or after DMM repaired the game), so it
    # is created here rather than only in the branch above.
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

    $dataDst = Join-Path $cacheDir '__data'
    $infoDst = Join-Path $cacheDir '__info'
    Copy-Item -LiteralPath $LangBundlePath -Destination $dataDst -Force
    $epoch = [int][double]::Parse((Get-Date -UFormat %s))
    [IO.File]::WriteAllText($infoDst, "-1`n$epoch`n1`n__data`n")

    return [pscustomobject]@{
        CacheDir = $cacheDir
        DataMd5  = Get-Md5 $dataDst
        SizeOk   = ((Get-Item $dataDst).Length -eq $ExpectedSize)
    }
}

Export-ModuleMember -Function Get-Md5, Get-RemoteFile, Get-Prop, Get-UnityCachePublisherDir, Get-LangCacheDir, Get-LangBundleHash, Get-GameDir, Get-GameDirFromDmmConfig, Get-ReleaseInfo, Get-PcLanguages, Get-PatchArtifacts, Get-VerifiedFile, Install-LanguageCache `
                    -Variable Repo, Release, ReleaseBase, LangFileName, InappFileName, InappMetaName, PrefabZipName, PrefabImagesZipName, VersionFile, `
                              GameProcessName, GameExeName, InappRelPath, BootCfgRelPath, `
                              LangBundleGuid, LangBundleHash, LangBundleSize, PatchDataDir

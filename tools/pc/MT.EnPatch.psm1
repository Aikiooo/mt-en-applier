# MT.EnPatch.psm1 - self-contained helpers + constants for the PC English patch.
# Import-Module this file; no dot-sourcing of config.ps1 required.

Set-StrictMode -Version Latest

# --- constants (module scope) -------------------------------------------------
$script:Repo          = 'Aikiooo/mt-en-applier'
$script:Release       = 'patch-latest'
$script:ReleaseBase   = "https://github.com/$($script:Repo)/releases/download/$($script:Release)"

$script:LangFileName  = 'language-ja_en.bundle'      # exact-size, CRC-forged language bundle
$script:InappFileName = 'inapp_assets_all_en.bundle'  # EN inapp asset patch
$script:VersionFile   = 'version.json'

$script:GameProcessName = 'mushoku_coe_cl'
$script:GameExeName     = 'mushoku_coe_cl.exe'
$script:InappRelPath    = 'mushoku_coe_cl_Data\StreamingAssets\aa\StandaloneWindows64\inapp_assets_all.bundle'
$script:BootCfgRelPath  = 'mushoku_coe_cl_Data\boot.config'

# Unity Addressables cache of the language bundle. The path lives under the
# per-user "LocalLow" folder, which has no reliable env var on every Windows
# version, so candidate roots are globbed rather than built from $env:LOCALAPPDATA.
$script:LangBundleGuid = 'cad73e991807559422ab03e01424a9d3'
$script:LangBundleHash = '133414c00d6dd88d834135f255cf7efc'
$script:LangBundleSize = 1797998
$script:PatchDataDir = Join-Path $env:LOCALAPPDATA 'MT-EN-Applier\pc'

# Resolve the non-ASCII Unity publisher cache dir ("GREE Entertainment_<クロエコ>")
# by searching the usual LocalLow locations.
function Get-UnityCachePublisherDir {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Low\Unity'),
        (Join-Path $env:USERPROFILE 'AppData\LocalLow\Unity'),
        (Join-Path (Split-Path $env:APPDATA -Parent) 'LocalLow\Unity')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    foreach ($root in $candidates) {
        $pub = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like 'GREE Entertainment*' } | Select-Object -First 1
        if ($pub) { return $pub.FullName }
    }
    return $null
}

function Get-Md5 {
    param([Parameter(Mandatory)][string]$Path)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { ($md5.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $fs.Close(); $md5.Dispose() }
}

# Resolve the full language-bundle cache dir (…\GREE Entertainment_*\<guid>\<hash>).
# The asset-hash subfolder changes on some updates, so prefer the NEWEST hash
# folder the game has actually written (that is the one the catalog pins);
# fall back to the known-current $script:LangBundleHash only when no folder
# exists yet (fresh install: the installer creates it before the game runs).
function Get-LangCacheDir {
    $pub = Get-UnityCachePublisherDir
    if (-not $pub) { return $null }
    $guidDir = Join-Path $pub $script:LangBundleGuid
    $live = Get-ChildItem -LiteralPath $guidDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($live) { return $live.FullName }
    return (Join-Path $guidDir $script:LangBundleHash)
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

# Download + verify the patch artifacts from the rolling release. Returns a
# hashtable @{ Files = @{lang;inapp}; Want = @{lang;inapp} }.
function Get-PatchArtifacts {
    param([switch]$Force)
    New-Item -ItemType Directory -Force -Path $script:PatchDataDir | Out-Null

    $versionPath = Join-Path $script:PatchDataDir $script:VersionFile
    Invoke-WebRequest -UseBasicParsing -Uri "$($script:ReleaseBase)/$($script:VersionFile)" -OutFile $versionPath
    $version = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
    $pcProp = $version.PSObject.Properties['pc']
    if (-not $pcProp) { throw 'version.json on the release has no "pc" block yet. Publish the PC build first (maintainer\Publish-PcPatch.ps1).' }

    $want = @{ lang = $version.pc.language_ja_en; inapp = $version.pc.inapp_assets_all_en }
    $files = @{
        lang  = Join-Path $script:PatchDataDir $script:LangFileName
        inapp = Join-Path $script:PatchDataDir $script:InappFileName
    }
    $urls = @{
        lang  = "$($script:ReleaseBase)/$($script:LangFileName)"
        inapp = "$($script:ReleaseBase)/$($script:InappFileName)"
    }

    foreach ($k in 'lang','inapp') {
        $dst = $files[$k]; $exp = $want[$k]
        $need = $Force -or -not (Test-Path $dst) -or ((Get-Item $dst).Length -ne [int64]$exp.size) -or ((Get-Md5 $dst) -ne $exp.md5)
        if ($need) {
            Write-Host "  downloading $(Split-Path $dst -Leaf) ..."
            Invoke-WebRequest -UseBasicParsing -Uri $urls[$k] -OutFile $dst
        }
        $actualSize = (Get-Item $dst).Length
        $actualMd5  = Get-Md5 $dst
        if ($actualSize -ne [int64]$exp.size -or $actualMd5 -ne $exp.md5) {
            throw "Integrity check failed for $(Split-Path $dst -Leaf): size $actualSize/$($exp.size), md5 $actualMd5/$($exp.md5). Re-run with -Force."
        }
    }
    return @{ Version = $version; Files = $files; Want = $want }
}

# Seed the exact-size EN language bundle into the Unity cache __data (catalog untouched).
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
        $cacheDir = Join-Path $pub (Join-Path $script:LangBundleGuid $script:LangBundleHash)
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    }

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

Export-ModuleMember -Function Get-Md5, Get-UnityCachePublisherDir, Get-LangCacheDir, Get-GameDir, Get-GameDirFromDmmConfig, Get-PatchArtifacts, Install-LanguageCache `
                    -Variable Repo, Release, ReleaseBase, LangFileName, InappFileName, VersionFile, `
                              GameProcessName, GameExeName, InappRelPath, BootCfgRelPath, `
                              LangBundleGuid, LangBundleHash, LangBundleSize, PatchDataDir

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
$script:LangBundleHash = '38cff80d239fcb3c117a8ef461f5a462'
$script:LangBundleSize = 1777229
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
function Get-LangCacheDir {
    $pub = Get-UnityCachePublisherDir
    if (-not $pub) { return $null }
    return (Join-Path $pub (Join-Path $script:LangBundleGuid $script:LangBundleHash))
}

# Locate the game install root (the folder that contains mushoku_coe_cl.exe).
function Get-GameDir {
    param([string]$Override)
    if ($Override) {
        if (Test-Path (Join-Path $Override $script:GameExeName)) { return $Override }
        throw "Game exe not found under -GameDir '$Override'."
    }
    $proc = Get-Process -Name $script:GameProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) { return (Split-Path $proc.Path -Parent) }
    $roots = @('D:\Games','C:\Games','D:\','C:\') | Where-Object { Test-Path $_ }
    foreach ($r in $roots) {
        $hit = Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
               Where-Object { Test-Path (Join-Path $_.FullName $script:GameExeName) } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
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
    param([Parameter(Mandatory)][string]$LangBundlePath)
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
        SizeOk   = ((Get-Item $dataDst).Length -eq $script:LangBundleSize)
    }
}

Export-ModuleMember -Function Get-Md5, Get-UnityCachePublisherDir, Get-LangCacheDir, Get-GameDir, Get-PatchArtifacts, Install-LanguageCache `
                    -Variable Repo, Release, ReleaseBase, LangFileName, InappFileName, VersionFile, `
                              GameProcessName, GameExeName, InappRelPath, BootCfgRelPath, `
                              LangBundleGuid, LangBundleHash, LangBundleSize, PatchDataDir

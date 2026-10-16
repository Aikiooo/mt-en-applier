# Mushoku Tensei PC translation patch - one-line web installer (DMM GAME PLAYER).
#
# Paste into PowerShell (no download, no unzip):
#   irm https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/install.ps1 | iex
#
# With options (-Language <code>, -GameDir <folder>, -Check, -Restore, -Force):
#   & ([scriptblock]::Create((irm https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/install.ps1))) -Check
#
# The installer asks one thing: whether to also install the redrawn images
# (logos, banners, buttons, tutorial captions). Text and prefabs install without
# asking; the images come inside the same download, so answering no saves no
# bandwidth. The question defaults to yes, and sixty seconds of silence means
# yes. Answer it up front instead:
#   & ([scriptblock]::Create((irm .../install.ps1))) -WithAssets     # yes, no question
#   & ([scriptblock]::Create((irm .../install.ps1))) -NoImages       # text only, no question
#   & ([scriptblock]::Create((irm .../install.ps1))) -LanguageOnly   # language bundle only
# -WithAssets is -Prefabs (English text and images in the cached UI bundles, ~55 MB
# download) plus -FirstLoad (the English in-app bundle for the first load's title
# screen, swapped in per session by Watch-InappSwap.ps1). Either can be used alone.
#
# This only fetches the same installer that ships in the zip (Install-EnPatch.ps1
# + MT.EnPatch.psm1, plus the two helper scripts for -Prefabs/-FirstLoad) from the
# same release and runs it in a child Windows PowerShell with the execution policy
# bypassed for that one process. So it works on a default Windows install (where
# scripts are blocked), and an error never closes the window you pasted into. The
# installer then downloads the patch and checks its size + md5 against
# version.json, exactly like the zip.

& {
    param([string]$GameDir, [string]$Language, [switch]$Force, [switch]$Check, [switch]$Restore,
          [switch]$Prefabs, [switch]$FirstLoad, [switch]$WithAssets, [switch]$LanguageOnly, [switch]$NoImages)

    $ErrorActionPreference = 'Stop'
    # Windows PowerShell 5.1 can default to TLS 1.0; GitHub needs 1.2.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $base = 'https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest'
    if ($env:MT_EN_RELEASE_BASE) { $base = $env:MT_EN_RELEASE_BASE.TrimEnd('/') }   # testing only

    $dir = Join-Path $env:LOCALAPPDATA 'MT-EN-Applier\pc\installer'
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Write-Host 'MT-EN: fetching the installer ...'
        foreach ($f in 'Install-EnPatch.ps1', 'MT.EnPatch.psm1', 'Install-PrefabPatch.ps1', 'Watch-InappSwap.ps1') {
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$f" -OutFile (Join-Path $dir $f)
        }
    } catch {
        Write-Host "Could not download the installer: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Check your internet connection, or use the zip from the Releases page instead.'
        return
    }

    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dir 'Install-EnPatch.ps1'))
    if ($GameDir) { $a += @('-GameDir', $GameDir) }
    if ($Force) { $a += '-Force' }
    if ($Language) { $a += @('-Language', $Language) }
    if ($Check) { $a += '-Check' }
    if ($Restore) { $a += '-Restore' }
    if ($Prefabs) { $a += '-Prefabs' }
    if ($FirstLoad) { $a += '-FirstLoad' }
    if ($WithAssets) { $a += '-WithAssets' }
    if ($LanguageOnly) { $a += '-LanguageOnly' }
    if ($NoImages) { $a += '-NoImages' }
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @a
} @args

<#
.SYNOPSIS
  English patch for the iPhone / iPad version, installed from this PC over Wi-Fi (no cable).

.DESCRIPTION
  Starts mitmproxy (official standalone build, downloaded once to %LOCALAPPDATA%\MT-EN-iOS
  and checked against its SHA-256) in WireGuard mode with the mt_en_ios.py addon, and opens
  the step-by-step page in the browser. The iPhone joins with the free WireGuard app (QR
  code on that page). Only the game's download server is intercepted; all other traffic
  passes through untouched. Close this window to stop.

.PARAMETER Release
  Release that holds ios-manifest.json and the patched bundles.
#>
param(
    [string]$Release = "https://github.com/Aikiooo/mt-en-applier/releases/download/ios-latest",
    [int]$Port = 51820
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$MitmVersion = "12.2.3"
$MitmSha256 = "04a01ea95ae96df75058a893e774957d294e69012dab1f4e256ce2b0c6725483"
$Home_ = Join-Path $env:LOCALAPPDATA "MT-EN-iOS"
$Bin = Join-Path $Home_ "mitmproxy-$MitmVersion"
$Exe = Join-Path $Bin "mitmdump.exe"
$Addon = Join-Path $PSScriptRoot "mt_en_ios.py"

Write-Host ""
Write-Host "  MT English Patch for iPhone / iPad" -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path $Exe)) {
    New-Item -ItemType Directory -Force $Bin | Out-Null
    $zip = Join-Path $Home_ "mitmproxy.zip"
    Write-Host "  First run: downloading mitmproxy $MitmVersion (86 MB, once)..."
    Invoke-WebRequest "https://downloads.mitmproxy.org/$MitmVersion/mitmproxy-$MitmVersion-windows-x86_64.zip" -OutFile $zip
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $MitmSha256) {
        Remove-Item $zip
        throw "mitmproxy download doesn't match the expected SHA-256 ($hash). Nothing was installed."
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $z.Entries | Where-Object { $_.Name -eq "mitmdump.exe" } | Select-Object -First 1
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $Exe, $true)
    } finally { $z.Dispose() }
    Remove-Item $zip
}

Write-Host "  A browser page opens with the steps. If Windows asks about network access,"
Write-Host "  tick 'Private networks' and click Allow (the iPhone connects through it)."
Write-Host ""
Write-Host "  Keep this window open while the game downloads; close it when you're done."
Write-Host ""

& $Exe `
    --mode "wireguard@$Port" `
    --set "confdir=$(Join-Path $Home_ 'conf')" `
    --set "allow_hosts=^mushokutensei-coe-jp\.akamaized\.net(:443)?$" `
    --set "allow_hosts=^10\.0\.0\.53(:80)?$" `
    --set block_global=false `
    --set connection_strategy=lazy `
    --set http3=false `
    --set http2=false `
    --set stream_large_bodies=1m `
    --set flow_detail=0 `
    --set termlog_verbosity=warn `
    --set "mt_release=$Release" `
    --set "mt_home=$Home_" `
    -s $Addon

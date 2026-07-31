<#
  reapply-en-patch.ps1 — PC method (Method 2) for the Mushoku Tensei
  (Chronicle of Echoes) English patch. Works on:
    * Google Play Games PC emulator      (adb on localhost:6520, root)
    * BlueStacks 5                        (root + adb enabled)
    * any emulator / phone with ROOT      (adb + su)
    * any phone WITHOUT root              (adb via Shizuku's shell uid)

  WHY THIS SCRIPT EXISTS
  The game keeps its text bundle at
      Android/data/jp.gree_ent.mushoku/files/UnityCache/Shared/<name-hash>/<content-hash>/__data
  Every content update makes a NEW <content-hash> folder and re-downloads the
  Japanese data into it, so the patch "stops working" until it is re-copied.
  The encryption key is NOT rotated by updates, so the same __data keeps working.
  This script FINDS the current folder by size+signature (no hardcoded hash) so it
  keeps working across updates and across devices (the <name-hash> group folder
  differs between a physical phone and an emulator).

  It AUTO-DOWNLOADS the patch from the rolling `patch-latest` GitHub release and
  verifies size+md5 against `version.json`, so you do not need the file locally.

  USAGE
    powershell -ExecutionPolicy Bypass -File reapply-en-patch.ps1 -Check
    powershell -ExecutionPolicy Bypass -File reapply-en-patch.ps1
    powershell -ExecutionPolicy Bypass -File reapply-en-patch.ps1 -Serial 127.0.0.1:6520
    powershell -ExecutionPolicy Bypass -File reapply-en-patch.ps1 -Patch C:\path\__data
    powershell -ExecutionPolicy Bypass -File reapply-en-patch.ps1 -Revert

  PARAMETERS
    -Serial  <adb serial>   device to use (auto-detected if only one is connected)
    -Patch   <path>         use a local __data instead of downloading
    -Revert                 restore the Japanese original from the on-device backup
    -Check                  report readiness, change nothing
#>
param(
    [string]$Serial,
    [string]$Patch,
    [switch]$Revert,
    [switch]$Check
)

$ErrorActionPreference = "Continue"   # native stderr must not abort the script
$PKG = "jp.gree_ent.mushoku"
$REL = "https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest"

function Fail($msg) { Write-Host "`nERROR: $msg" -ForegroundColor Red; exit 1 }
function Ok($msg)   { Write-Host "  OK   $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  WARN $msg" -ForegroundColor Yellow }
function Info($msg) { Write-Host "  ..   $msg" -ForegroundColor DarkGray }

Write-Host "`n=== Mushoku Tensei EN patch — PC / emulator method ===" -ForegroundColor Cyan

# ---------------------------------------------------------------- locate adb
$adb = $null
foreach ($c in @(
    (Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"),
    "C:\Program Files\BlueStacks_nxt\HD-Adb.exe",
    "C:\Program Files (x86)\BlueStacks_nxt\HD-Adb.exe",
    "C:\Program Files\Google\Play Games\current\emulator\adb.exe"
)) { if (Test-Path $c) { $adb = $c; break } }
if (-not $adb) { $g = Get-Command adb -ErrorAction SilentlyContinue; if ($g) { $adb = $g.Source } }
if (-not $adb) { Fail "adb not found. Install Android platform-tools (or enable ADB in your emulator)." }
Write-Host "adb   : $adb"

# ---------------------------------------------------------------- pick device
if (-not $Serial) {
    & $adb start-server | Out-Null
    $devs = (& $adb devices) -split "`n" | Where-Object { $_ -match "`tdevice$" }
    if (-not $devs) { & $adb connect localhost:6520 | Out-Null; Start-Sleep -Milliseconds 800 }
    $devs = (& $adb devices) -split "`n" | ForEach-Object { ($_ -split "`t")[0].Trim() } |
            Where-Object { $_ -and $_ -notmatch "^List" }
    if (-not $devs)  { Fail "No ADB device. Connect one / start your emulator (GPG tries localhost:6520 automatically)." }
    if ($devs.Count -gt 1) { Fail "Several devices connected ($($devs -join ', ')). Re-run with -Serial followed by one of them." }
    $Serial = $devs[0]
}
Write-Host "device: $Serial"
$state = (& $adb -s $Serial get-state 2>&1)
if ($state -notmatch "device") { Fail "Device $Serial not reachable ($state)." }

function Dev($cmd) { & $adb -s $Serial shell $cmd 2>&1 }

# ---------------------------------------------------------------- game installed
$installed = (Dev ('pm path ' + $PKG))
if ($installed -notmatch 'package:') {
    Fail ('Game not installed on ' + $Serial + '.' + "`n" + '  Install the game, launch it once to the title screen, then re-run.')
}
Ok 'game installed'

# ---------------------------------------------------------------- how do we write to the cache?
# Rooted  -> su -c '...'
# No root -> plain 'adb shell' runs as the 'shell' uid; with Shizuku started via
#   adb shell sh /sdcard/Android/data/moe.shizuku.privileged.api/start.sh
#   that SAME shell uid can already write the game's cache (the exact privilege
#   the Android app uses). We detect which one works.
$cacheRoot = '/sdcard/Android/data/' + $PKG + '/files'
$wrapper = $null
$probe = Dev 'su -c "id -u" 2>/dev/null'
if ($probe -match '^\s*0\s*$') { $wrapper = 'su'; Ok 'write access: root (su)' }
else {
    $wrapper = 'sh'
    Dev ('touch ' + $cacheRoot + '/.mtwtest') | Out-Null
    $t = Dev ('ls ' + $cacheRoot + '/.mtwtest')
    Dev ('rm -f ' + $cacheRoot + '/.mtwtest') | Out-Null
    if ($t -match '\.mtwtest') {
        Ok 'write access: shell uid (no root needed - Shizuku-style)'
    } else {
        Fail ("No write access to the game cache.`n" +
              '  * Rooted device/emulator: enable root (BlueStacks: settings; GPG dev build has it).' + "`n" +
              '  * Non-rooted phone: install Shizuku, then run once:' + "`n" +
              '      adb -s ' + $Serial + ' shell sh /sdcard/Android/data/moe.shizuku.privileged.api/start.sh' + "`n" +
              '    then re-run this script (the adb shell gains write access while Shizuku is running).')
    }
}
function W($cmd) { if ($wrapper -eq 'su') { Dev ("su -c '" + $cmd + "'") } else { Dev $cmd } }

# ---------------------------------------------------------------- find the live __data by size
# Generic scan: every __data under the game's UnityCache Shared dirs, keep ones
# whose size is in the plausible masterdata range (1.5-2.5 MB). No hardcoded hash,
# so it survives updates and phone-vs-emulator group-folder differences.
$found = @()
$dirs = (Dev ('find ' + $cacheRoot + ' -type d -name Shared')) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
foreach ($d in $dirs) {
    $files = (W ('find "' + $d + '" -name __data -type f')) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($f in $files) {
        $sz = (W ('stat -c %s "' + $f + '"')) -as [long]
        if ($sz -ge 1500000 -and $sz -le 2500000) { $found += [pscustomobject]@{ Path = $f; Size = $sz } }
    }
}
if (-not $found) {
    Fail ('No masterdata bundle found under ' + $cacheRoot + ".`n  Launch the game once (to the title screen) so it downloads its data, then retry.")
}
Write-Host "bundle candidate(s):"
foreach ($b in $found) { Write-Host ('  ' + $b.Size + '  ' + $b.Path) }

if ($Check) {
    Write-Host "`n-Check complete: device reachable, bundle found." -ForegroundColor Cyan
    Write-Host "Write access method: $wrapper. Re-run without -Check to apply."
    exit 0
}

# ---------------------------------------------------------------- obtain the patch (download unless given)
$tmpPatch = $null
if (-not $Patch) {
    Info 'downloading version.json + __data from the patch-latest release'
    try { $vj = Invoke-RestMethod -Uri ($REL + '/version.json') -UseBasicParsing -TimeoutSec 30 }
    catch { Fail ('Could not download version.json from ' + $REL + ' (' + $_.Exception.Message + ')') }
    $tmpPatch = Join-Path $env:TEMP 'mt_en___data'
    try { Invoke-WebRequest -Uri ($REL + '/__data') -OutFile $tmpPatch -UseBasicParsing -TimeoutSec 120 }
    catch { Fail ('Could not download __data from ' + $REL + ' (' + $_.Exception.Message + ')') }
    $dlLen = (Get-Item $tmpPatch).Length
    if ($vj.size -and $dlLen -ne [long]$vj.size) { Fail ('Downloaded size ' + $dlLen + ' != expected ' + $vj.size + '. Try -Patch with a local file.') }
    $dlMd5 = (Get-FileHash $tmpPatch -Algorithm MD5).Hash.ToLower()
    if ($vj.md5 -and $dlMd5 -ne $vj.md5.ToLower()) { Fail ('Downloaded md5 ' + $dlMd5 + ' != expected ' + $vj.md5 + '. Try -Patch with a local file.') }
    Ok ('downloaded patch (' + $dlLen + ' bytes, md5 verified)')
    $Patch = $tmpPatch
} elseif (-not (Test-Path $Patch)) {
    Fail ('-Patch file not found: ' + $Patch)
}
$md5 = (Get-FileHash $Patch -Algorithm MD5).Hash.ToLower()
Ok ('patch file: ' + $Patch + '  (md5 ' + $md5 + ')')

# ---------------------------------------------------------------- apply / revert
Dev ('am force-stop ' + $PKG) | Out-Null
Start-Sleep -Seconds 2
$staging = '/sdcard/Download/__data.patch'
if (-not $Revert) { & $adb -s $Serial push $Patch $staging | Out-Null }

$applied = 0
foreach ($b in $found) {
    $target = $b.Path
    $sub = ($target -split '/')[-2]
    $backup = '/sdcard/Download/__data.jp.' + $sub + '.backup'

    $tExists = W ('ls "' + $target + '"')
    if ($tExists -notmatch '__data') { Warn ('skipping ' + $target + ' - no __data there yet (launch the game once)'); continue }

    $before = ((W ('md5sum "' + $target + '"')) -split '\s+')[0]
    Write-Host "`ntarget : $target"
    Write-Host "current: $before"

    if ($Revert) {
        $hasBk = W ('ls "' + $backup + '"')
        if ($hasBk -notmatch 'backup') { Warn ('no backup at ' + $backup + ' - skipping'); continue }
        W ('cat "' + $backup + '" > "' + $target + '"') | Out-Null
        Write-Host 'reverted to the Japanese original'
        $applied++; continue
    }

    if ($before -ne $md5) {
        $hasBk = W ('ls "' + $backup + '"')
        if ($hasBk -notmatch 'backup') { W ('cat "' + $target + '" > "' + $backup + '"') | Out-Null; Write-Host ('japanese original backed up -> ' + $backup) }
        W ('cat "' + $staging + '" > "' + $target + '"') | Out-Null
    } else { Write-Host 'already patched' }

    $after = ((W ('md5sum "' + $target + '"')) -split '\s+')[0]
    Write-Host "now    : $after"
    if ($after -eq $md5) { Ok 'English patch applied'; $applied++ }
    else { Warn ('md5 mismatch after write (expected ' + $md5 + ', got ' + $after + ')') }
}
if (-not $Revert) { Dev ('rm -f ' + $staging) | Out-Null }

if ($applied -eq 0) { Fail 'Nothing was changed.' }
Write-Host ('Done - ' + $applied + ' bundle(s) patched. Launch the game to verify.') -ForegroundColor Cyan
Write-Host 'Note: some labels (menu icons) are baked images, not text - they stay Japanese.'



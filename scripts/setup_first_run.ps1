# First-run setup: detect LDPlayer/ADB, install Magisk + CaptureCli, inject CA, smoke START.
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup_first_run.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup_first_run.ps1 -Serial 127.0.0.1:5555 -LdIndex 0

param(
  [string]$Serial = "127.0.0.1:5555",
  [int]$LdIndex = 0,
  [string]$AdbExe = "",
  [string]$LdConsole = "",
  [switch]$SkipMagiskInstall,
  [switch]$SkipSmoke
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "Resolve-Env.ps1")
$E = Resolve-SkillEnv -AdbExe $AdbExe -Serial $Serial -LdConsole $LdConsole -LdIndex $LdIndex
Write-EnvReport $E

if (-not $E.Adb) { throw "adb.exe not found. Install Android platform-tools and add to PATH (or set ANDROID_HOME)." }
if (-not (Test-Path $E.CaptureCliApk)) { throw "Missing assets/CaptureCli.apk in skill package." }

function Adb {
  # Use automatic $args (do not name a param $Args — breaks binding)
  & $E.Adb -s $E.Serial @args
}

# --- launch emulator if needed ---
& $E.Adb start-server 2>$null | Out-Null
& $E.Adb connect $E.Serial 2>$null | Out-Null
$st = (& $E.Adb -s $E.Serial get-state 2>$null | Out-String).Trim()
if ($st -ne "device") {
  if (-not $E.LdConsole) { throw "Emulator not connected and ldconsole.exe not found. Start LDPlayer manually, then retry." }
  Write-Host "launching LDPlayer index=$($E.LdIndex) ..."
  & $E.LdConsole launch --index $E.LdIndex | Out-Null
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep 3
    & $E.Adb connect $E.Serial 2>$null | Out-Null
    $st = (& $E.Adb -s $E.Serial get-state 2>$null | Out-String).Trim()
    $boot = (& $E.Adb -s $E.Serial shell getprop sys.boot_completed 2>$null | Out-String).Trim()
    Write-Host "  wait[$i] state=$st boot=$boot"
    if ($st -eq "device" -and $boot -eq "1") { break }
  }
}
$st = (& $E.Adb -s $E.Serial get-state 2>$null | Out-String).Trim()
if ($st -ne "device") { throw "device not ready: $st" }
Write-Host "device OK"

# Magisk manager APK is optional in-repo; user must supply assets/Magisk.apk (gitignored).
if (-not $SkipMagiskInstall) {
  if (-not (Test-Path $E.MagiskApk)) {
    Write-Host "WARN: assets/Magisk.apk missing (not shipped on GitHub — GPL policy)."
    Write-Host "      Download official Magisk from https://github.com/topjohnwu/Magisk/releases"
    Write-Host "      Save as: $($E.MagiskApk)"
  } else {
    $hasMagisk = (Adb shell pm path io.github.huskydg.magisk 2>$null | Out-String) + (Adb shell pm path com.topjohnwu.magisk 2>$null | Out-String)
    if ($hasMagisk -notmatch "package:") {
      Write-Host "installing Magisk manager from assets/Magisk.apk ..."
      $magiskTmp = Join-Path $env:TEMP "skill_Magisk.apk"
      Copy-Item $E.MagiskApk $magiskTmp -Force
      Adb install -r -g $magiskTmp | Out-Host
    } else {
      Write-Host "Magisk package already installed"
    }
  }
}

# --- root check ---
$su = (Adb shell "su 0 id" 2>&1 | Out-String)
Write-Host "su check: $($su.Trim())"
if ($su -notmatch "uid=0") {
  Write-Host "WARN: su not working yet. Open Magisk in emulator, grant root, then re-run this script."
  Write-Host "      LDPlayer usually needs a Magisk-patched / rooted image — Magisk.apk alone is the manager."
}

# --- CaptureCli ---
Write-Host "installing CaptureCli..."
$cliTmp = Join-Path $env:TEMP "skill_CaptureCli.apk"
Copy-Item $E.CaptureCliApk $cliTmp -Force
Adb install -r -g $cliTmp | Out-Host

# --- CA + reverse ---
if ($E.MitmDump -or (Get-Command python -EA SilentlyContinue)) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "capture.ps1") ca -Adb $E.Adb -Serial $E.Serial 2>&1 | Select-Object -Last 6
} else {
  Write-Host "WARN: mitmdump/python missing — skip CA inject for now. Install mitmproxy later."
}
Adb reverse --remove-all 2>$null | Out-Null
Adb reverse tcp:8080 tcp:8080 | Out-Host

if (-not $SkipSmoke -and $su -match "uid=0") {
  Write-Host "smoke START (package=com.android.settings as harmless target if needed)..."
  $pkg = "com.android.ld.appstore"
  $p = (Adb shell pm path $pkg 2>$null | Out-String)
  if ($p -notmatch "package:") { $pkg = "com.android.settings" }
  Adb shell am broadcast -a com.capturecli.START -n com.capturecli/.CliReceiver --es package $pkg --es proxy "127.0.0.1:8080" | Out-Host
  for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep 1
    $status = (Adb shell cat /sdcard/capturecli-status.txt 2>$null | Out-String).Trim()
    Write-Host "  [$i] $status"
    if ($status -match 'mode=root-redirect' -or $status -match '^error=') { break }
  }
  Adb shell am broadcast -a com.capturecli.STOP -n com.capturecli/.CliReceiver | Out-Null
  Start-Sleep 1
  Write-Host "final status: $((Adb shell cat /sdcard/capturecli-status.txt 2>$null | Out-String).Trim())"
}

Write-Host ""
Write-Host "First-run setup finished."
Write-Host "Next: run analyze_one_by_one.ps1 -ListFile <apk_list.txt> -OutDir <report_dir>"

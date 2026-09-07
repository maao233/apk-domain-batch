# Shared environment resolver for apk-domain-batch skill (cross-machine).
# Dot-source: . "$PSScriptRoot\Resolve-Env.ps1"

$ErrorActionPreference = "Continue"

# Skill root = parent of scripts/
$script:SkillRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:SkillAssets = Join-Path $SkillRoot "assets"
$script:SkillScripts = Join-Path $SkillRoot "scripts"
$script:SkillOut = Join-Path $SkillRoot "out"
New-Item -ItemType Directory -Force -Path $SkillOut | Out-Null

function Find-OnPath([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Find-File([string[]]$Candidates) {
  foreach ($c in $Candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
  }
  return $null
}

function Find-Adb {
  # Prefer skill-bundled platform-tools
  $bundled = Join-Path $SkillRoot "tools\platform-tools\adb.exe"
  if (Test-Path -LiteralPath $bundled) { return (Resolve-Path -LiteralPath $bundled).Path }
  $fromPath = Find-OnPath "adb.exe"
  if ($fromPath) { return $fromPath }
  return Find-File @(
    (Join-Path $env:ANDROID_HOME "platform-tools\adb.exe"),
    (Join-Path $env:ANDROID_SDK_ROOT "platform-tools\adb.exe"),
    (Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"),
    "$env:USERPROFILE\AppData\Local\Android\Sdk\platform-tools\adb.exe",
    "C:\Android\platform-tools\adb.exe",
    "C:\platform-tools\adb.exe"
  )
}

function Find-Aapt {
  $fromPath = Find-OnPath "aapt.exe"
  if ($fromPath) { return $fromPath }
  $roots = @(
    $env:ANDROID_HOME,
    $env:ANDROID_SDK_ROOT,
    (Join-Path $env:LOCALAPPDATA "Android\Sdk"),
    "$env:USERPROFILE\AppData\Local\Android\Sdk"
  ) | Where-Object { $_ }
  foreach ($r in $roots) {
    $hit = Get-ChildItem -Path (Join-Path $r "build-tools") -Recurse -Filter "aapt.exe" -ErrorAction SilentlyContinue |
      Sort-Object FullName -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  # LDPlayer often ships aapt
  $ld = Find-LdConsole
  if ($ld) {
    $dir = Split-Path $ld -Parent
    $a = Join-Path $dir "aapt.exe"
    if (Test-Path $a) { return $a }
  }
  return $null
}

function Find-LdConsole {
  $fromPath = Find-OnPath "ldconsole.exe"
  if ($fromPath) { return $fromPath }
  return Find-File @(
    "C:\LDPlayer\LDPlayer9\ldconsole.exe",
    "D:\LDPlayer\LDPlayer9\ldconsole.exe",
    "E:\LDPlayer\LDPlayer9\ldconsole.exe",
    "F:\LDPlayer\LDPlayer9\ldconsole.exe",
    "C:\leidian\LDPlayer9\ldconsole.exe",
    "D:\leidian\LDPlayer9\ldconsole.exe",
    "E:\leidian\LDPlayer9\ldconsole.exe",
    "F:\leidian\LDPlayer9\ldconsole.exe",
    "${env:ProgramFiles}\LDPlayer\LDPlayer9\ldconsole.exe",
    "${env:ProgramFiles(x86)}\LDPlayer\LDPlayer9\ldconsole.exe"
  )
}

function Find-MitmDump {
  $fromPath = Find-OnPath "mitmdump.exe"
  if ($fromPath) { return $fromPath }
  $hits = @(
    Get-ChildItem "$env:USERPROFILE\AppData\Roaming\Python" -Recurse -Filter "mitmdump.exe" -ErrorAction SilentlyContinue |
      Select-Object -First 3 -ExpandProperty FullName
  )
  if ($hits.Count -gt 0) { return $hits[0] }
  $hits2 = @(
    Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Recurse -Filter "mitmdump.exe" -ErrorAction SilentlyContinue |
      Select-Object -First 1 -ExpandProperty FullName
  )
  if ($hits2.Count -gt 0) { return $hits2[0] }
  return $null
}

function Resolve-SkillEnv {
  param(
    [string]$AdbExe = "",
    [string]$Serial = "127.0.0.1:5555",
    [string]$Aapt = "",
    [string]$LdConsole = "",
    [string]$MitmDump = "",
    [int]$LdIndex = 0
  )
  $adb = if ($AdbExe) { $AdbExe } else { Find-Adb }
  $aapt = if ($Aapt) { $Aapt } else { Find-Aapt }
  $ld = if ($LdConsole) { $LdConsole } else { Find-LdConsole }
  $mitm = if ($MitmDump) { $MitmDump } else { Find-MitmDump }

  $envMap = [ordered]@{
    SkillRoot     = $SkillRoot
    Assets        = $SkillAssets
    Scripts       = $SkillScripts
    OutDir        = $SkillOut
    CaptureCliApk = Join-Path $SkillAssets "CaptureCli.apk"
    MagiskApk     = Join-Path $SkillAssets "Magisk.apk"
    Adb           = $adb
    Aapt          = $aapt
    LdConsole     = $ld
    MitmDump      = $mitm
    Serial        = $Serial
    LdIndex       = $LdIndex
    TmpApk        = Join-Path $env:TEMP "capturecli_one.apk"
  }
  return [pscustomobject]$envMap
}

function Write-EnvReport($EnvObj) {
  Write-Host "=== apk-domain-batch env ==="
  Write-Host "SkillRoot : $($EnvObj.SkillRoot)"
  Write-Host "Adb       : $($EnvObj.Adb)"
  Write-Host "Aapt      : $($EnvObj.Aapt)"
  Write-Host "LdConsole : $($EnvObj.LdConsole)"
  Write-Host "MitmDump  : $($EnvObj.MitmDump)"
  Write-Host "Serial    : $($EnvObj.Serial)"
  Write-Host "CaptureCli: $($EnvObj.CaptureCliApk) exists=$(Test-Path $EnvObj.CaptureCliApk)"
  Write-Host "Magisk    : $($EnvObj.MagiskApk) exists=$(Test-Path $EnvObj.MagiskApk)"
}

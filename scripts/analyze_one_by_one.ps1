# One-by-one: install -> capture -> domain -> uninstall (skill-bundled, portable)
param(
  [Parameter(Mandatory = $true)]
  [string]$ListFile,
  [string]$OutDir = "",
  [string]$AdbExe = "",
  [string]$Serial = "127.0.0.1:5555",
  [string]$Aapt = "",
  [string]$LdConsole = "",
  [int]$LdIndex = 0,
  [int]$StartIndex = 0,
  [int]$Count = 1,
  [int]$DumpWaitSec = 10,
  [int]$AfterTapSec = 12
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "Resolve-Env.ps1")
$E = Resolve-SkillEnv -AdbExe $AdbExe -Serial $Serial -Aapt $Aapt -LdConsole $LdConsole -LdIndex $LdIndex
if (-not $E.Adb) { throw "adb.exe not found (PATH or ANDROID_HOME)" }
if (-not $OutDir) { $OutDir = Join-Path $E.OutDir ("run_" + (Get-Date -Format "yyyyMMdd_HHmmss")) }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Write-EnvReport $E

$AdbExe = $E.Adb
$Serial = $E.Serial
$Aapt = $E.Aapt
$MitmDump = $E.MitmDump
$Ld = $E.LdConsole
$UrlsFile = Join-Path $OutDir "urls_current.txt"
$ReportCsv = Join-Path $OutDir "domains.csv"
$TmpApk = $E.TmpApk
$Noise = @('google','googleapis','gstatic','firebase','crashlytics','facebook','bugly','umeng','appjiagu','360.cn','sayhi.360','qihoo','sentry','baidu.com','amap.com','jpush','igexin','getui','cloudflare','adobe.com','mozilla.org','yahoo.com','bing.com','microsoft.com','publicsuffix.org','fragment.com','purl.org','iec.ch','gnu.org','comodo.net','doh.pub','w3.org')

function Invoke-Adb {
  param([Parameter(Mandatory)][string[]]$CmdArgs)
  & $AdbExe -s $Serial @CmdArgs
}

function Ensure-Device {
  Invoke-Adb -CmdArgs @("connect", $Serial) 2>$null | Out-Null
  $st = (Invoke-Adb -CmdArgs @("get-state") 2>$null | Out-String).Trim()
  if ($st -eq "device") { return $true }
  if (-not $Ld) {
    Write-Host "ldconsole not found; cannot auto-start emulator"
    return $false
  }
  Write-Host "starting emulator index=$LdIndex ..."
  & $Ld launch --index $LdIndex | Out-Null
  for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep 3
    Invoke-Adb -CmdArgs @("connect", $Serial) 2>$null | Out-Null
    $st = (Invoke-Adb -CmdArgs @("get-state") 2>$null | Out-String).Trim()
    $boot = (Invoke-Adb -CmdArgs @("shell", "getprop", "sys.boot_completed") 2>$null | Out-String).Trim()
    Write-Host "  wait[$i] state=$st boot=$boot"
    if ($st -eq "device" -and $boot -eq "1") { return $true }
  }
  return $false
}

function Get-PackageName([string]$apk) {
  if (-not $Aapt) { throw "aapt.exe not found (Android build-tools or LDPlayer aapt)" }
  # aapt often fails on non-ASCII paths — always dump via ASCII temp copy
  $probe = Join-Path $env:TEMP ("skill_aapt_probe_" + [guid]::NewGuid().ToString("N") + ".apk")
  try {
    Copy-Item -LiteralPath $apk -Destination $probe -Force
    $line = & $Aapt dump badging $probe 2>$null | Where-Object { $_ -match "^package:" } | Select-Object -First 1
    if ($line -match "name='([^']+)'") { return $Matches[1] }
    return $null
  } finally {
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-Mitm {
  $listening = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
  if ($listening) { return }
  if (-not $MitmDump) { Write-Host "WARN: mitmdump not found — MITM URLs disabled; static fallback only"; return }
  $py = Join-Path $OutDir "dump_urls.py"
  $pathEsc = $UrlsFile.Replace('\', '\\')
  @"
from mitmproxy import http
class Dump:
    def request(self, flow: http.HTTPFlow):
        with open(r"$pathEsc", "a", encoding="utf-8") as f:
            f.write(f"{flow.request.method} {flow.request.pretty_url}\n")
addons = [Dump()]
"@ | Set-Content $py -Encoding UTF8
  Start-Process -FilePath $MitmDump -ArgumentList @("-s", $py, "--listen-host", "127.0.0.1", "--listen-port", "8080", "-q") -WindowStyle Minimized | Out-Null
  Start-Sleep 2
}

function Get-HostStats([string]$path) {
  $hosts = @{}
  if (-not (Test-Path $path)) { return @() }
  Get-Content $path -EA SilentlyContinue | ForEach-Object {
    if ($_ -match 'https?://([^/:\s]+)') {
      $h = $Matches[1].ToLower()
      if ($h -match '^\d+\.\d+\.\d+\.\d+$') { return }
      if (-not $hosts.ContainsKey($h)) { $hosts[$h] = 0 }
      $hosts[$h]++
    }
  }
  return @($hosts.GetEnumerator() | Sort-Object Value -Descending)
}

function Pick-Main($stats) {
  if (-not $stats -or $stats.Count -eq 0) {
    return [pscustomobject]@{ Main = '(none)'; All = '' }
  }
  $all = ($stats | ForEach-Object { "$($_.Key)($($_.Value))" }) -join '; '
  $candidates = @()
  foreach ($e in $stats) {
    $noisy = $false
    foreach ($n in $Noise) { if ($e.Key -like "*$n*") { $noisy = $true; break } }
    # discard short/junk hosts like g.net, eg.net, www.icon
    $labels = $e.Key.Split('.')
    $sld = if ($labels.Count -ge 2) { $labels[-2] } else { $e.Key }
    if ($sld.Length -lt 4) { $noisy = $true }
    if ($e.Key -match '^www\.[a-z]+$' -or $e.Key -notmatch '\.[a-z]{2,}$') { $noisy = $true }
    if ($noisy) { continue }
    $candidates += $e
  }
  if ($candidates.Count -eq 0) {
    return [pscustomobject]@{ Main = [string]$stats[0].Key; All = $all }
  }
  # prefer highest count, then longer SLD (business domain style)
  $best = $candidates | Sort-Object @{Expression='Value';Descending=$true}, @{Expression={ $_.Key.Split('.')[-2].Length }; Descending=$true} | Select-Object -First 1
  return [pscustomobject]@{ Main = [string]$best.Key; All = $all }
}

function Get-StaticHosts([string]$apk) {
  $py = Join-Path $OutDir "extract_hosts_once.py"
  $apkEsc = $apk.Replace('\', '\\')
  @"
import re, zipfile, collections
apk = r"$apkEsc"
c = collections.Counter()
skip = ('google','facebook','umeng','bugly','appjiagu','example','apache','android.com','schema.org','w3.org','webrtc','ietf.org','github.com','youtube.com','comodoca','globalsign','public-trust','crbug','videolan','aomediacodec','go.dev','duckduckgo','brave.com','telegram.org','t.me')
with zipfile.ZipFile(apk) as z:
    for n in z.namelist():
        try: data = z.read(n)
        except Exception: continue
        for m in re.findall(rb'https?://([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})', data):
            h = m.decode('ascii','ignore').lower()
            if any(x in h for x in skip): continue
            if h.count('.') < 1: continue
            c[h] += 1
for h, n in c.most_common(15):
    print(f'{h}|{n}')
"@ | Set-Content $py -Encoding UTF8
  $lines = @(python $py 2>$null)
  $hosts = @{}
  foreach ($line in $lines) {
    if ($line -match '^([^|]+)\|(\d+)$') { $hosts[$Matches[1]] = [int]$Matches[2] }
  }
  return @($hosts.GetEnumerator() | Sort-Object Value -Descending)
}

function Uninstall-Quiet([string]$pkg) {
  if (-not $pkg) { return }
  Invoke-Adb -CmdArgs @("shell", "am", "force-stop", $pkg) 2>$null | Out-Null
  Invoke-Adb -CmdArgs @("uninstall", $pkg) 2>$null | Out-Host
}

function Get-BoundsCenter([string]$Bounds) {
  if ($Bounds -notmatch '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') { return $null }
  $l = [int]$Matches[1]; $t = [int]$Matches[2]
  $r = [int]$Matches[3]; $b = [int]$Matches[4]
  if ($r -le $l -or $b -le $t) { return $null }
  return @{
    X = [int](($l + $r) / 2)
    Y = [int](($t + $b) / 2)
    W = ($r - $l)
    H = ($b - $t)
    Bounds = $Bounds
  }
}

function Dump-UiXml([string]$LocalPath) {
  $remote = "/sdcard/_capturecli_ui.xml"
  Invoke-Adb -CmdArgs @("shell", "rm", "-f", $remote) 2>$null | Out-Null
  Invoke-Adb -CmdArgs @("shell", "uiautomator", "dump", $remote) 2>$null | Out-Null
  Invoke-Adb -CmdArgs @("pull", $remote, $LocalPath) 2>$null | Out-Null
  if (-not (Test-Path $LocalPath)) { return $null }
  return (Get-Content -Raw -Encoding UTF8 $LocalPath)
}

function Find-LoginClickTargets([string]$UiXml) {
  if (-not $UiXml) { return @() }
  # High-priority login / register (literal match, case-insensitive)
  $hiLit = @(
    '登录','登入','登陆','login','signin','sign in','log_in','log in',
    '注册','signup','sign up','register'
  )
  # Secondary: consent / enter / continue
  $loLit = @(
    '同意并继续','同意','允许','allow','agree','accept',
    '开始','进入','下一步','继续','continue','next','start',
    '立即体验','跳过','skip','确定','我知道了','ok'
  )
  $targets = @()
  $nodeRe = [regex]'<node\b(?<attrs>[^>]*)>'
  foreach ($m in $nodeRe.Matches($UiXml)) {
    $a = $m.Groups['attrs'].Value
    if ($a -notmatch 'clickable="true"') { continue }
    if ($a -match 'enabled="false"') { continue }
    $text = if ($a -match 'text="([^"]*)"') { $Matches[1] } else { '' }
    $desc = if ($a -match 'content-desc="([^"]*)"') { $Matches[1] } else { '' }
    $rid  = if ($a -match 'resource-id="([^"]*)"') { $Matches[1] } else { '' }
    $cls  = if ($a -match 'class="([^"]*)"') { $Matches[1] } else { '' }
    $bnd  = if ($a -match 'bounds="([^"]*)"') { $Matches[1] } else { '' }
    $c = Get-BoundsCenter $bnd
    if (-not $c) { continue }
    # skip full-screen / huge overlay clickables
    if ($c.W -ge 1000 -and $c.H -ge 1400) { continue }
    if ($c.W -lt 40 -or $c.H -lt 30) { continue }

    $blob = ("$text $desc $rid").ToLowerInvariant()
    $score = 0
    $label = ''
    foreach ($k in $hiLit) {
      if ($blob.Contains($k.ToLowerInvariant())) { $score = 100; $label = "$text|$desc|$rid"; break }
    }
    if ($score -eq 0) {
      foreach ($k in $loLit) {
        if ($blob.Contains($k.ToLowerInvariant())) { $score = 50; $label = "$text|$desc|$rid"; break }
      }
    }
    # resource-id / class hint: *login* *sign*
    if ($score -eq 0 -and ($rid -match '(?i)login|signin|sign_in|register|signup')) {
      $score = 90; $label = "$text|$desc|$rid"
    }
    if ($score -eq 0) { continue }
    if ($cls -match 'Button|TextView|CheckedTextView|ImageButton') { $score += 5 }
    if ($c.Y -ge 700) { $score += 3 }
    $targets += [pscustomobject]@{
      Score = $score; X = $c.X; Y = $c.Y; W = $c.W; H = $c.H
      Label = $label; Bounds = $c.Bounds
    }
  }
  return @(
    $targets | Sort-Object `
      @{ Expression = 'Score'; Descending = $true }, `
      @{ Expression = { $_.W * $_.H }; Ascending = $true }
  )
}

function Invoke-LoginUiInteract([string]$DumpName) {
  $local = Join-Path $OutDir $DumpName
  $xml = Dump-UiXml $local
  if (-not $xml) {
    Write-Host "ui dump failed -> blind taps"
    Invoke-Adb -CmdArgs @("shell", "input", "tap", "540", "1500") 2>$null | Out-Null
    Start-Sleep 2
    Invoke-Adb -CmdArgs @("shell", "input", "tap", "540", "1100") 2>$null | Out-Null
    return 'blind'
  }

  $hits = Find-LoginClickTargets $xml
  if ($hits.Count -eq 0) {
    Write-Host "no login-related clickable -> blind taps x2"
    Invoke-Adb -CmdArgs @("shell", "input", "tap", "540", "1500") 2>$null | Out-Null
    Start-Sleep 2
    Invoke-Adb -CmdArgs @("shell", "input", "tap", "540", "1100") 2>$null | Out-Null
    return 'blind'
  }

  # tap up to 2 best distinct targets
  $used = @{}
  $n = 0
  foreach ($h in $hits) {
    $key = "$($h.X),$($h.Y)"
    if ($used.ContainsKey($key)) { continue }
    $used[$key] = $true
    Write-Host ("ui tap[{0}] ({1},{2}) score={3} {4}" -f $n, $h.X, $h.Y, $h.Score, $h.Label)
    Invoke-Adb -CmdArgs @("shell", "input", "tap", "$($h.X)", "$($h.Y)") 2>$null | Out-Null
    Start-Sleep 2
    $n++
    if ($n -ge 2) { break }
  }
  return "ui:$n"
}

# ---- main ----
if (-not (Ensure-Device)) { throw "emulator not ready" }
Ensure-Mitm
Invoke-Adb -CmdArgs @("reverse", "--remove-all") 2>$null | Out-Null
Invoke-Adb -CmdArgs @("reverse", "tcp:8080", "tcp:8080") | Out-Null

# inject CA once (skill-bundled capture.ps1)
$ca = Join-Path $PSScriptRoot "capture.ps1"
if (Test-Path $ca) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $ca ca -Adb $AdbExe -Serial $Serial 2>&1 | Select-Object -Last 5
}

if (-not (Test-Path $ReportCsv)) {
  "apk,package,main_domain,all_hosts,status" | Set-Content $ReportCsv -Encoding UTF8
}

$apks = @(Get-Content $ListFile | Where-Object { $_ -and (Test-Path $_) })
$end = [Math]::Min($StartIndex + $Count, $apks.Count) - 1
Write-Host "Will analyze index $StartIndex..$end of $($apks.Count)"

for ($idx = $StartIndex; $idx -le $end; $idx++) {
  $apk = $apks[$idx]
  $name = [IO.Path]::GetFileName($apk)
  Write-Host ""
  Write-Host "======== [$($idx+1)/$($apks.Count)] ONLY this app: $name ========"

  if (-not (Ensure-Device)) {
    Add-Content $ReportCsv "`"$name`",,,,device_offline"
    continue
  }

  $pkg = Get-PackageName $apk
  if (-not $pkg) {
    Write-Host "parse package failed"
    Add-Content $ReportCsv "`"$name`",,,,parse_fail"
    continue
  }
  Write-Host "package=$pkg"

  # ensure clean: stop capture, uninstall any previous target
  Invoke-Adb -CmdArgs @("shell", "am", "broadcast", "-a", "com.capturecli.STOP", "-n", "com.capturecli/.CliReceiver") 2>$null | Out-Null
  Uninstall-Quiet $pkg

  # Always install from TEMP ASCII path (avoid non-ASCII adb install failures)
  Copy-Item $apk $TmpApk -Force
  $inst = (Invoke-Adb -CmdArgs @("install", "-r", "-g", $TmpApk) 2>&1 | Out-String)
  if ($inst -notmatch "Success") {
    Write-Host "install fail: $inst"
    Add-Content $ReportCsv "`"$name`",$pkg,,,install_fail"
    continue
  }
  Write-Host "installed OK"

  Set-Content $UrlsFile "" -Encoding UTF8
  Invoke-Adb -CmdArgs @("reverse", "tcp:8080", "tcp:8080") 2>$null | Out-Null
  $bc = (Invoke-Adb -CmdArgs @("shell", "am", "broadcast", "-a", "com.capturecli.START", "-n", "com.capturecli/.CliReceiver", "--es", "package", $pkg, "--es", "proxy", "127.0.0.1:8080") 2>&1 | Out-String)
  Write-Host $bc.Trim()

  # Poll status until root-redirect / global-proxy (START now runs in receiver goAsync)
  $status = ""
  for ($w = 0; $w -lt 20; $w++) {
    Start-Sleep 1
    $status = (Invoke-Adb -CmdArgs @("shell", "su", "0", "cat", "/sdcard/capturecli-status.txt") 2>$null | Out-String).Trim()
    if ($status -match 'mode=(root-redirect|global-proxy)') { break }
    if ($status -match '^error=') { break }
  }
  Write-Host "capture status: $status"
  if ($status -notmatch 'mode=(root-redirect|global-proxy)') {
    Write-Host "WARN: capture not ready — retry START once"
    Invoke-Adb -CmdArgs @("shell", "am", "broadcast", "-a", "com.capturecli.START", "-n", "com.capturecli/.CliReceiver", "--es", "package", $pkg, "--es", "proxy", "127.0.0.1:8080") 2>$null | Out-Null
    Start-Sleep 5
    $status = (Invoke-Adb -CmdArgs @("shell", "su", "0", "cat", "/sdcard/capturecli-status.txt") 2>$null | Out-String).Trim()
    Write-Host "capture status(retry): $status"
  }

  # launch ONLY this package -> wait for startup -> dump UI -> login tap or blind
  Invoke-Adb -CmdArgs @("shell", "monkey", "-p", $pkg, "-c", "android.intent.category.LAUNCHER", "1") 2>$null | Out-Null
  Write-Host "waiting ${DumpWaitSec}s for app startup before uiautomator dump..."
  Start-Sleep $DumpWaitSec
  $safeDump = ($name -replace '[^\w\.-]', '_')
  $uiMode = Invoke-LoginUiInteract "${safeDump}.ui.xml"
  Write-Host "ui interact mode=$uiMode"
  Start-Sleep $AfterTapSec

  $pick = Pick-Main (Get-HostStats $UrlsFile)
  $source = 'mitm'
  if ($pick.Main -eq '(none)') {
    $staticPick = Pick-Main (Get-StaticHosts $apk)
    if ($staticPick.Main -ne '(none)') {
      $pick = $staticPick
      $source = 'static'
    }
  }
  Write-Host "MAIN_DOMAIN=$($pick.Main) source=$source"
  Write-Host "ALL_HOSTS=$($pick.All)"
  $safe = ($name -replace '[^\w\.-]', '_')
  Copy-Item $UrlsFile (Join-Path $OutDir "$safe.urls.txt") -Force
  Add-Content $ReportCsv ('"{0}",{1},{2},"{3}",{4}' -f $name, $pkg, $pick.Main, $pick.All, $source)

  # stop capture then DELETE this app before next
  Invoke-Adb -CmdArgs @("shell", "am", "broadcast", "-a", "com.capturecli.STOP", "-n", "com.capturecli/.CliReceiver") 2>$null | Out-Null
  Uninstall-Quiet $pkg
  Write-Host "deleted $pkg — ready for next"
}

Write-Host ""
Write-Host "CSV: $ReportCsv"
Get-Content $ReportCsv

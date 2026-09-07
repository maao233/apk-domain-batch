# Model-driven UI loop for apk-domain-batch.
# After install: wait 10s -> dump XML + screenshot; Agent decides taps; dump/shot again.
#   prepare  -Apk <path> [-WaitSec 10]
#   dump | shot | dumpshot
#   tap -X N -Y N
#   swipe -X N -Y N -X2 N -Y2 N
#   key -Key KEYCODE_BACK
#   text -Text "..."
#   finish
param(
  [Parameter(Position = 0, Mandatory = $true)]
  [ValidateSet("prepare", "dump", "shot", "dumpshot", "tap", "swipe", "key", "text", "back", "home", "finish", "status", "mitm", "staticfail")]
  [string]$Action,

  [string]$Apk = "",
  [string]$OutDir = "",
  [string]$AdbExe = "",
  [string]$Serial = "127.0.0.1:5555",
  [string]$Aapt = "",
  [int]$WaitSec = 10,
  [int]$X = 0,
  [int]$Y = 0,
  [int]$X2 = 0,
  [int]$Y2 = 0,
  [string]$Text = "",
  [string]$Key = "KEYCODE_BACK"
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "Resolve-Env.ps1")
$E = Resolve-SkillEnv -AdbExe $AdbExe -Serial $Serial -Aapt $Aapt
if (-not $E.Adb) { throw "adb.exe not found" }
if (-not $OutDir) { $OutDir = Join-Path $E.OutDir "run_model_9.7" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$AdbExe = $E.Adb
$Serial = $E.Serial
$Aapt = $E.Aapt
$MitmDump = $E.MitmDump
$LdConsole = $E.LdConsole
$LdIndex = $E.LdIndex
$TmpApk = $E.TmpApk
$UrlsFile = Join-Path $OutDir "urls_current.txt"
$ReportCsv = Join-Path $OutDir "domains.csv"
$StateFile = Join-Path $OutDir "current.json"
$SumPy = Join-Path $PSScriptRoot "summarize_ui.py"
$Noise = @('google','googleapis','gstatic','firebase','crashlytics','facebook','bugly','umeng','appjiagu','360.cn','sayhi.360','qihoo','sentry','baidu.com','amap.com','jpush','igexin','getui','cloudflare','adobe.com','mozilla.org','yahoo.com','bing.com','microsoft.com','publicsuffix.org','fragment.com','purl.org','iec.ch','gnu.org','comodo.net','doh.pub','w3.org')

function Invoke-Adb {
  param([Parameter(Mandatory)][string[]]$CmdArgs)
  & $AdbExe -s $Serial @CmdArgs
}

function Invoke-AdbTimeout {
  param(
    [Parameter(Mandatory)][string[]]$CmdArgs,
    [int]$Ms = 10000
  )
  $out = Join-Path $env:TEMP ("adb_out_" + [guid]::NewGuid().ToString("N") + ".txt")
  $err = Join-Path $env:TEMP ("adb_err_" + [guid]::NewGuid().ToString("N") + ".txt")
  try {
    $p = Start-Process -FilePath $AdbExe -ArgumentList (@("-s", $Serial) + $CmdArgs) -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if (-not $p.WaitForExit($Ms)) {
      Write-Host "adb timeout ${Ms}ms: $($CmdArgs -join ' ')"
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
      return "TIMEOUT"
    }
    $so = if (Test-Path $out) { Get-Content $out -Raw -EA SilentlyContinue } else { "" }
    $se = if (Test-Path $err) { Get-Content $err -Raw -EA SilentlyContinue } else { "" }
    return "$so$se"
  } finally {
    Remove-Item $out, $err -Force -EA SilentlyContinue
  }
}

function Wait-PackageManager {
  for ($i = 0; $i -lt 4; $i++) {
    Invoke-Adb -CmdArgs @("connect", $Serial) 2>$null | Out-Null
    $p = Invoke-AdbTimeout -Ms 5000 -CmdArgs @("shell", "pm", "path", "android")
    if ($p -match "package:") {
      Write-Host "package manager OK"
      return $true
    }
    Write-Host "wait pm [$i] $p"
    Start-Sleep 3
  }
  return $false
}

function Get-State {
  if (-not (Test-Path $StateFile)) { return $null }
  return (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-State($obj) {
  ($obj | ConvertTo-Json -Depth 6) | Set-Content $StateFile -Encoding UTF8
}

function Get-PackageName([string]$apk) {
  if (-not $Aapt) { throw "aapt.exe not found" }
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

function Ensure-MitmUrls {
  $py = Join-Path $OutDir "dump_urls.py"
  $pathEsc = $UrlsFile.Replace('\', '\\')
  @"
from mitmproxy import http
class Dump:
    def request(self, flow: http.HTTPFlow):
        with open(r"$pathEsc", "a", encoding="utf-8") as f:
            f.write(flow.request.method + " " + flow.request.pretty_url + "\n")
addons = [Dump()]
"@ | Set-Content $py -Encoding UTF8
  if (-not (Test-Path $UrlsFile)) { Set-Content $UrlsFile "" -Encoding UTF8 }

  $listening = @(Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue)
  if ($listening.Count -gt 0) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($listening[0].OwningProcess)" -ErrorAction SilentlyContinue
    $cmd = [string]$p.CommandLine
    if ($cmd -match "dump_urls\.py") {
      Write-Host "mitmdump already dumping URLs"
      return
    }
    Write-Host "replacing host mitmdump on :8080 with dump_urls.py (emulator untouched)"
    Stop-Process -Id $listening[0].OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
  }
  if (-not $MitmDump) { Write-Host "WARN: mitmdump not found"; return }
  Start-Process -FilePath $MitmDump -ArgumentList @("-s", $py, "--listen-host", "127.0.0.1", "--listen-port", "8080", "-q") -WindowStyle Minimized | Out-Null
  Start-Sleep 2
  Write-Host "started mitmdump + dump_urls.py"
}

function Invoke-DumpXml {
  param([string]$LocalPath)
  $remote = "/sdcard/_capturecli_ui.xml"
  Invoke-AdbTimeout -Ms 20000 -CmdArgs @("shell", "rm", "-f", $remote) | Out-Null
  Write-Host (Invoke-AdbTimeout -Ms 25000 -CmdArgs @("shell", "uiautomator", "dump", $remote))
  Write-Host (Invoke-AdbTimeout -Ms 15000 -CmdArgs @("pull", $remote, $LocalPath))
  return (Test-Path $LocalPath)
}

function Invoke-Shot {
  param([string]$LocalPath)
  $remote = "/sdcard/_capturecli_shot.png"
  Invoke-Adb -CmdArgs @("shell", "screencap", "-p", $remote) 2>$null | Out-Null
  Invoke-Adb -CmdArgs @("pull", $remote, $LocalPath) 2>&1 | Out-Host
  return (Test-Path $LocalPath)
}

function Show-Clickables([string]$XmlPath) {
  if (-not (Test-Path $XmlPath)) { Write-Host "no xml"; return }
  $txt = [IO.Path]::ChangeExtension($XmlPath, ".clickables.txt")
  python $SumPy $XmlPath 1080 1920 | Tee-Object -FilePath $txt | Out-Host
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

switch ($Action) {
  "mitm" { Ensure-MitmUrls; break }

  "status" {
    $st = Get-State
    Write-Host "device=$(Invoke-Adb -CmdArgs @('get-state') | Out-String)"
    Write-Host "capture=$(Invoke-Adb -CmdArgs @('shell','cat','/sdcard/capturecli-status.txt') 2>$null | Out-String)"
    if ($st) { $st | ConvertTo-Json | Out-Host }
    if (Test-Path $UrlsFile) {
      Write-Host "urls lines=$((Get-Content $UrlsFile | Measure-Object -Line).Lines)"
      Get-Content $UrlsFile -Tail 15
    }
    break
  }

  "prepare" {
    if (-not $Apk -or -not (Test-Path -LiteralPath $Apk)) { throw "prepare requires -Apk existing file" }
    if (-not (Test-Path $ReportCsv)) {
      "apk,package,main_domain,all_hosts,status" | Set-Content $ReportCsv -Encoding UTF8
    }
    Ensure-MitmUrls
    Invoke-Adb -CmdArgs @("connect", $Serial) 2>$null | Out-Null
    $pkg = Get-PackageName $Apk
    if (-not $pkg) { throw "parse package failed" }
    $name = [IO.Path]::GetFileName($Apk)
    Write-Host "package=$pkg name=$name"
    Invoke-Adb -CmdArgs @("connect", $Serial) 2>$null | Out-Null

    Copy-Item -LiteralPath $Apk $TmpApk -Force
    if (-not $LdConsole) { throw "ldconsole.exe not found; cannot install while pm is unreliable" }
    Write-Host "ldconsole uninstallapp $pkg (ignore errors)"
    & $LdConsole uninstallapp --index $LdIndex --packagename $pkg 2>&1 | Out-Host
    Start-Sleep 2
    Write-Host "ldconsole installapp index=$LdIndex"
    $ldOut = & $LdConsole installapp --index $LdIndex --filename $TmpApk 2>&1 | Out-String
    Write-Host $ldOut
    Start-Sleep 8
    Write-Host "installed via ldconsole (skip pm path)"
    $inst = "Success"

    Set-Content $UrlsFile "" -Encoding UTF8
    Invoke-Adb -CmdArgs @("reverse", "--remove-all") 2>$null | Out-Null
    Invoke-Adb -CmdArgs @("reverse", "tcp:8080", "tcp:8080") | Out-Host

    $caOk = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "ls", "/system/etc/security/cacerts/c8750f0d.0")
    if ($caOk -notmatch "c8750f0d") {
      $ca = Join-Path $PSScriptRoot "capture.ps1"
      & powershell -NoProfile -ExecutionPolicy Bypass -File $ca ca -Adb $AdbExe -Serial $Serial 2>&1 | Select-Object -Last 4 | Out-Host
    } else {
      Write-Host "CA already present, skip inject"
    }

    Write-Host (Invoke-AdbTimeout -Ms 12000 -CmdArgs @("shell", "am", "broadcast", "-a", "com.capturecli.START", "-n", "com.capturecli/.CliReceiver", "--es", "package", $pkg, "--es", "proxy", "127.0.0.1:8080"))
    $status = ""
    for ($w = 0; $w -lt 12; $w++) {
      Start-Sleep 1
      $status = (Invoke-AdbTimeout -Ms 5000 -CmdArgs @("shell", "su", "0", "cat", "/sdcard/capturecli-status.txt")).Trim()
      if ($status -match 'mode=(root-redirect|global-proxy)' -or $status -match '^error=' -or $status -eq "TIMEOUT") { break }
    }
    Write-Host "capture status: $status"

    Write-Host "ldconsole runapp $pkg"
    & $LdConsole runapp --index $LdIndex --packagename $pkg 2>&1 | Out-Host
    Write-Host "waiting ${WaitSec}s then dump XML + screenshot..."
    Start-Sleep $WaitSec

    $safe = ($name -replace '[^\w\.-]', '_')
    $round = 1
    $xml = Join-Path $OutDir ("{0}.r{1}.ui.xml" -f $safe, $round)
    $png = Join-Path $OutDir ("{0}.r{1}.png" -f $safe, $round)
    Invoke-DumpXml $xml | Out-Null
    Invoke-Shot $png | Out-Null
    Show-Clickables $xml
    Write-Host "XML=$xml"
    Write-Host "PNG=$png"

    Save-State ([pscustomobject]@{
      apk = $Apk; name = $name; package = $pkg; safe = $safe; round = $round
      xml = $xml; png = $png; started = (Get-Date -Format o)
    })
    Write-Host "READY_FOR_MODEL_TAP"
    break
  }

  "dump" {
    $st = Get-State
    if (-not $st) { throw "no current.json — run prepare first" }
    $st.round = [int]$st.round + 1
    $xml = Join-Path $OutDir ("{0}.r{1}.ui.xml" -f $st.safe, $st.round)
    Invoke-DumpXml $xml | Out-Null
    $st.xml = $xml
    Save-State $st
    Show-Clickables $xml
    Write-Host "XML=$xml"
    break
  }

  "shot" {
    $st = Get-State
    if (-not $st) { throw "no current.json — run prepare first" }
    $png = Join-Path $OutDir ("{0}.r{1}.png" -f $st.safe, $st.round)
    Invoke-Shot $png | Out-Null
    $st.png = $png
    Save-State $st
    Write-Host "PNG=$png"
    break
  }

  "dumpshot" {
    $st = Get-State
    if (-not $st) { throw "no current.json — run prepare first" }
    $st.round = [int]$st.round + 1
    $xml = Join-Path $OutDir ("{0}.r{1}.ui.xml" -f $st.safe, $st.round)
    $png = Join-Path $OutDir ("{0}.r{1}.png" -f $st.safe, $st.round)
    Invoke-DumpXml $xml | Out-Null
    Invoke-Shot $png | Out-Null
    $st.xml = $xml; $st.png = $png
    Save-State $st
    Show-Clickables $xml
    Write-Host "XML=$xml"
    Write-Host "PNG=$png"
    break
  }

  "tap" {
    if ($X -le 0 -or $Y -le 0) { throw "tap requires -X -Y" }
    Write-Host "tap ($X,$Y)"
    Invoke-Adb -CmdArgs @("shell", "input", "tap", "$X", "$Y") | Out-Host
    break
  }

  "swipe" {
    Write-Host "swipe ($X,$Y)->($X2,$Y2)"
    Invoke-Adb -CmdArgs @("shell", "input", "swipe", "$X", "$Y", "$X2", "$Y2", "400") | Out-Host
    break
  }

  "key" {
    Invoke-Adb -CmdArgs @("shell", "input", "keyevent", $Key) | Out-Host
    break
  }

  "text" {
    $esc = $Text -replace ' ', '%s'
    Invoke-Adb -CmdArgs @("shell", "input", "text", $esc) | Out-Host
    break
  }

  "back" { Invoke-Adb -CmdArgs @("shell", "input", "keyevent", "KEYCODE_BACK") | Out-Host; break }
  "home" { Invoke-Adb -CmdArgs @("shell", "input", "keyevent", "KEYCODE_HOME") | Out-Host; break }

  "finish" {
    $st = Get-State
    if (-not $st) { throw "no current.json" }
    Start-Sleep 3
    $pick = Pick-Main (Get-HostStats $UrlsFile)
    $source = "mitm"
    $emptyMitm = (-not $pick.All) -or ([string]$pick.Main -match 'none')
    if ($emptyMitm) {
      $staticPick = Pick-Main (Get-StaticHosts $st.apk)
      if ($staticPick.Main -and ([string]$staticPick.Main -notmatch 'none')) {
        $pick = $staticPick
        $source = "static"
      } else {
        $source = "mitm_empty"
      }
    }
    Write-Host "MAIN_DOMAIN=$($pick.Main) source=$source"
    Write-Host "ALL_HOSTS=$($pick.All)"
    $urlCopy = Join-Path $OutDir ($st.safe + ".urls.txt")
    if (Test-Path $UrlsFile) { Copy-Item $UrlsFile $urlCopy -Force }
    Add-Content $ReportCsv ('"{0}",{1},{2},"{3}",{4}' -f $st.name, $st.package, $pick.Main, $pick.All, $source)
    Write-Host (Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "am", "broadcast", "-a", "com.capturecli.STOP", "-n", "com.capturecli/.CliReceiver"))
    Write-Host (Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "am", "force-stop", $st.package))
    if ($LdConsole) {
      Write-Host "ldconsole uninstallapp $($st.package)"
      & $LdConsole uninstallapp --index $LdIndex --packagename $st.package 2>&1 | Out-Host
    } else {
      Write-Host (Invoke-AdbTimeout -Ms 15000 -CmdArgs @("uninstall", $st.package))
    }
    Write-Host "deleted $($st.package)"
    Write-Host "CSV=$ReportCsv"
    break
  }

  "staticfail" {
    if (-not $Apk -or -not (Test-Path -LiteralPath $Apk)) { throw "staticfail requires -Apk" }
    if (-not (Test-Path $ReportCsv)) {
      "apk,package,main_domain,all_hosts,status" | Set-Content $ReportCsv -Encoding UTF8
    }
    $name = [IO.Path]::GetFileName($Apk)
    $pkg = ""
    try { $pkg = Get-PackageName $Apk } catch { $pkg = "" }
    $pick = Pick-Main (Get-StaticHosts $Apk)
    $src = if ($pick.Main -and ([string]$pick.Main -notmatch 'none')) { "static_install_fail" } else { "install_fail" }
    Write-Host "STATIC_FAIL $name MAIN=$($pick.Main)"
    Add-Content $ReportCsv ('"{0}",{1},{2},"{3}",{4}' -f $name, $pkg, $pick.Main, $pick.All, $src)
    Write-Host "CSV=$ReportCsv"
    break
  }
}

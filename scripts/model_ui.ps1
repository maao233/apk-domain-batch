# Model-driven UI helpers for apk-domain-batch.
# PS only: install / CaptureCli START / dump XML+shot / tap primitives / teardown.
# Agent: decide taps, handle errors, classify URLs, write CSV via `record`.
#
#   prepare  -Apk <path> [-WaitSec 10]   # no size skip
#   dump | shot | dumpshot
#   tap -X N -Y N | swipe | text | back | home | key
#   recover  — adb kill-server/start/connect after emulator reboot
#   rebootemu — quit+launch, wait device, inject CA (ready for NEXT apk)
#   health   — EMU_OK / EMU_HUNG (pm/shell ping; does not reboot)
#   status | mitm | classify
#   teardown   — STOP + uninstall (adb AND ldconsole) + save *.urls.txt (NO domain CSV)
#   uninstall  — force-remove -Package (or current.json); verify pm path gone
#   record     — Agent fills domains.csv after reading classify output
#   finish     — alias of teardown (kept for compatibility)
#   installfail — install/reboot failure row status=install_failed + static hints
#   staticfail — leftover alias; writes install_failed (not too_large)
param(
  [Parameter(Position = 0, Mandatory = $true)]
  [ValidateSet("prepare", "dump", "shot", "dumpshot", "tap", "swipe", "key", "text", "back", "home", "finish", "teardown", "uninstall", "record", "classify", "status", "mitm", "recover", "rebootemu", "health", "installfail", "staticfail")]
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
  [string]$Key = "KEYCODE_BACK",
  [double]$MaxMb = 0,
  # record fields (Agent-authored)
  [string]$MainDomain = "",
  [string]$ValuableDomains = "",
  [string]$EvidenceIds = "",
  [string]$AllHosts = "",
  [string]$Status = "mitm",
  [string]$Notes = "",
  [string]$Package = "",
  [string]$ApkName = ""
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
$ClassifyPy = Join-Path $PSScriptRoot "classify_capture.py"
$CsvHeader = "apk,package,main_domain,valuable_domains,evidence_ids,all_hosts,status,notes"
$Noise = @('google','googleapis','gstatic','firebase','crashlytics','facebook','bugly','umeng','appjiagu','360.cn','sayhi.360','qihoo','sentry','baidu.com','amap.com','jpush','igexin','getui','cloudflare','adobe.com','mozilla.org','yahoo.com','bing.com','microsoft.com','publicsuffix.org','fragment.com','purl.org','iec.ch','gnu.org','comodo.net','doh.pub','w3.org')

function Ensure-CsvHeader {
  if (-not (Test-Path $ReportCsv)) {
    $CsvHeader | Set-Content $ReportCsv -Encoding UTF8
    return
  }
  $first = Get-Content $ReportCsv -TotalCount 1 -EA SilentlyContinue
  if ($first -ne $CsvHeader) {
    Write-Host "WARN: domains.csv header is legacy/different; new rows use: $CsvHeader"
  }
}

function Escape-CsvField([string]$s) {
  if ($null -eq $s) { return "" }
  $t = [string]$s
  if ($t -match '[",\r\n]') { return '"' + ($t.Replace('"', '""')) + '"' }
  return $t
}

function Append-DomainRow {
  param(
    [string]$Name,
    [string]$Pkg,
    [string]$Main,
    [string]$Valuable,
    [string]$Evidence,
    [string]$All,
    [string]$Stat,
    [string]$Note
  )
  Ensure-CsvHeader
  $line = @(
    (Escape-CsvField $Name),
    (Escape-CsvField $Pkg),
    (Escape-CsvField $Main),
    (Escape-CsvField $Valuable),
    (Escape-CsvField $Evidence),
    (Escape-CsvField $All),
    (Escape-CsvField $Stat),
    (Escape-CsvField $Note)
  ) -join ','
  Add-Content $ReportCsv $line -Encoding UTF8
  Write-Host "CSV_ROW $line"
  Write-Host "CSV=$ReportCsv"
}

function Upsert-DomainRow {
  param(
    [string]$Name,
    [string]$Pkg,
    [string]$Main,
    [string]$Valuable,
    [string]$Evidence,
    [string]$All,
    [string]$Stat,
    [string]$Note
  )
  Ensure-CsvHeader
  $keep = @()
  if (Test-Path $ReportCsv) {
    try {
      $keep = @(Import-Csv $ReportCsv | Where-Object { [string]$_.apk -ne $Name })
    } catch { $keep = @() }
  }
  $CsvHeader | Set-Content $ReportCsv -Encoding UTF8
  foreach ($r in $keep) {
    $line = @(
      (Escape-CsvField ([string]$r.apk)),
      (Escape-CsvField ([string]$r.package)),
      (Escape-CsvField ([string]$r.main_domain)),
      (Escape-CsvField ([string]$r.valuable_domains)),
      (Escape-CsvField ([string]$r.evidence_ids)),
      (Escape-CsvField ([string]$r.all_hosts)),
      (Escape-CsvField ([string]$r.status)),
      (Escape-CsvField ([string]$r.notes))
    ) -join ','
    Add-Content $ReportCsv $line -Encoding UTF8
  }
  Append-DomainRow -Name $Name -Pkg $Pkg -Main $Main -Valuable $Valuable `
    -Evidence $Evidence -All $All -Stat $Stat -Note $Note
}

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

function Invoke-ProcTimeout {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string[]]$CmdArgs,
    [int]$Ms = 120000
  )
  $out = Join-Path $env:TEMP ("proc_out_" + [guid]::NewGuid().ToString("N") + ".txt")
  $err = Join-Path $env:TEMP ("proc_err_" + [guid]::NewGuid().ToString("N") + ".txt")
  try {
    $p = Start-Process -FilePath $FilePath -ArgumentList $CmdArgs -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if (-not $p.WaitForExit($Ms)) {
      Write-Host "proc timeout ${Ms}ms: $FilePath $($CmdArgs -join ' ')"
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
      Get-Process -Name "ldconsole" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
      return "TIMEOUT"
    }
    $so = if (Test-Path $out) { Get-Content $out -Raw -EA SilentlyContinue } else { "" }
    $se = if (Test-Path $err) { Get-Content $err -Raw -EA SilentlyContinue } else { "" }
    return "$so$se"
  } catch {
    return "ERR $($_.Exception.Message)"
  } finally {
    Remove-Item $out, $err -Force -EA SilentlyContinue
  }
}

function Reboot-Emulator {
  if (-not $LdConsole) { throw "ldconsole.exe not found; cannot reboot emulator" }
  Write-Host "ldconsole quit index=$LdIndex (then launch)"
  Write-Host (Invoke-ProcTimeout -FilePath $LdConsole -Ms 45000 -CmdArgs @("quit", "--index", "$LdIndex"))
  Start-Sleep 5
  $running = Invoke-ProcTimeout -FilePath $LdConsole -Ms 15000 -CmdArgs @("isrunning", "--index", "$LdIndex")
  Write-Host "isrunning after quit: $running"
  if ($running -match 'running') {
    Write-Host "quit did not stop instance; force-kill LDPlayer processes"
    foreach ($n in @('dnplayer','LdVBoxHeadless','Ld9BoxHeadless','LdVBoxSVC')) {
      Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep 4
  }
  Start-Sleep 4
  Write-Host (Invoke-ProcTimeout -FilePath $LdConsole -Ms 45000 -CmdArgs @("launch", "--index", "$LdIndex"))
  $recovered = $false
  for ($i = 0; $i -lt 36; $i++) {
    Start-Sleep 5
    $devs = & $AdbExe devices 2>&1 | Out-String
    Write-Host "wait reboot [$i] devices=$($devs.Trim())"
    if ($devs -notmatch 'emulator-\d+\s+device' -and $devs -notmatch '5555\s+device') { continue }
    if (-not $recovered) {
      Recover-Adb
      $recovered = $true
    }
    $st = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("get-state")
    $boot = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "getprop", "sys.boot_completed")
    Write-Host "wait reboot [$i] state=$st boot=$boot"
    if ($st -match "device" -and $boot -match "1") {
      if (Wait-PackageManager) {
        Write-Host "REBOOT_OK"
        return $true
      }
    }
  }
  Write-Host "REBOOT_WAIT_TIMEOUT"
  return $false
}

function Recover-Adb {
  Write-Host "recover adb (kill-server + start + connect $Serial)"
  & $AdbExe kill-server 2>$null | Out-Null
  Start-Sleep 2
  & $AdbExe start-server 2>$null | Out-Null
  Start-Sleep 2
  if ($Serial -match '^\d+\.\d+\.\d+\.\d+:') {
    & $AdbExe connect $Serial 2>$null | Out-Null
    Start-Sleep 1
  }
  # dual serial (5555 + 5554) often breaks streamed install
  if ($Serial -eq "emulator-5554") {
    & $AdbExe disconnect "127.0.0.1:5555" 2>$null | Out-Null
  }
}

function Wait-PackageManager {
  for ($i = 0; $i -lt 6; $i++) {
    if ($Serial -match '^\d+\.\d+\.\d+\.\d+:') {
      Invoke-Adb -CmdArgs @("connect", $Serial) 2>$null | Out-Null
    }
    $p = Invoke-AdbTimeout -Ms 5000 -CmdArgs @("shell", "pm", "path", "android")
    if ($p -match "package:") {
      Write-Host "package manager OK"
      return $true
    }
    Write-Host "wait pm [$i] $p"
    if ($p -match "offline|not found|no devices|TIMEOUT") { Recover-Adb }
    Start-Sleep 3
  }
  return $false
}

function Test-TextLooksHung([string]$t) {
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  return ($t -match 'TIMEOUT|Broken pipe|offline|not found|closed|protocol fault|waiting for device|Failure calling service package')
}

function Get-EmulatorHealth {
  $st = Invoke-AdbTimeout -Ms 6000 -CmdArgs @("get-state")
  if ($st -match 'TIMEOUT|offline|not found|unauthorized|error:') {
    return [pscustomobject]@{ Ok = $false; Reason = "state=$($st.Trim())" }
  }
  if ($st -notmatch 'device') {
    return [pscustomobject]@{ Ok = $false; Reason = "state=$($st.Trim())" }
  }
  $ping = Invoke-AdbTimeout -Ms 6000 -CmdArgs @("shell", "echo", "HEALTH_OK")
  if ($ping -notmatch 'HEALTH_OK') {
    return [pscustomobject]@{ Ok = $false; Reason = "shell=$($ping.Trim())" }
  }
  $pm = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "pm", "path", "android")
  if ($pm -notmatch 'package:') {
    return [pscustomobject]@{ Ok = $false; Reason = "pm=$($pm.Trim())" }
  }
  return [pscustomobject]@{ Ok = $true; Reason = "ok" }
}

function Wait-Root {
  for ($i = 0; $i -lt 18; $i++) {
    $id = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "su", "0", "id")
    if ($id -match "uid=0") {
      Write-Host "root OK"
      return $true
    }
    Write-Host "wait root [$i] $($id.Trim())"
    Start-Sleep 5
  }
  Write-Host "ROOT_WAIT_TIMEOUT"
  return $false
}

function Inject-MitmCa {
  $ca = Join-Path $PSScriptRoot "capture.ps1"
  Write-Host "inject CA (tmpfs)"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $ca ca -Adb $AdbExe -Serial $Serial -OutDir $OutDir 2>&1 | Out-Host
  $caOk = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "ls", "/system/etc/security/cacerts/c8750f0d.0")
  if ($caOk -match "c8750f0d") { Write-Host "CA_OK" } else { Write-Host "CA_FAIL $($caOk.Trim())" }
}

function Write-InstallFailedRow {
  param(
    [string]$Note,
    [string]$Pkg = ""
  )
  if (-not $Apk -or -not (Test-Path -LiteralPath $Apk)) {
    Write-Host "INSTALL_FAILED skip csv: no -Apk"
    return
  }
  Ensure-CsvHeader
  $name = [IO.Path]::GetFileName($Apk)
  $apkMb = [math]::Round((Get-Item -LiteralPath $Apk).Length / 1MB, 2)
  if (-not $Pkg) { $Pkg = $Package }
  if (-not $Pkg) {
    try { $Pkg = Get-PackageName $Apk } catch { $Pkg = "" }
  }
  $pick = Pick-Main (Get-StaticHosts $Apk)
  $main = if ($MainDomain) { $MainDomain } else { [string]$pick.Main }
  $all = if ($AllHosts) { $AllHosts } else { [string]$pick.All }
  $note = if ($Note) { $Note } else { "install_failed mb=$apkMb" }
  $val = if ($ValuableDomains) { $ValuableDomains } else { "n/a" }
  $ev = if ($EvidenceIds) { $EvidenceIds } else { "n/a" }
  Upsert-DomainRow -Name $name -Pkg $Pkg -Main $main -Valuable $val -Evidence $ev `
    -All $all -Stat "install_failed" -Note $note
  Write-Host "INSTALL_FAILED $name"
}

function Finish-RebootReady {
  param([switch]$ContinueThisApk)
  if (Wait-Root) { Inject-MitmCa }
  Invoke-AdbTimeout -Ms 8000 -CmdArgs @("reverse", "--remove-all") | Out-Null
  Write-Host (Invoke-AdbTimeout -Ms 8000 -CmdArgs @("reverse", "tcp:8080", "tcp:8080"))
  $caOk = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "ls", "/system/etc/security/cacerts/c8750f0d.0")
  Write-Host "ca-file=$caOk"
  if ($ContinueThisApk) {
    Write-Host "EMU_RECOVERED continue THIS apk"
  } else {
    Write-Host "NEXT_APK_READY"
  }
}

function Recover-FromHang {
  param(
    [string]$Reason,
    [switch]$FailCurrentApk,
    [switch]$ContinueThisApk
  )
  Write-Host "HUNG_DETECTED $Reason"
  $stNow = Get-State
  $failPkg = $Package
  if ($FailCurrentApk) {
    if (-not $failPkg) {
      try { $failPkg = Get-PackageName $Apk } catch { $failPkg = "" }
    }
    Write-InstallFailedRow -Note "install_failed hung: $Reason; no retry; rebooted for next apk" -Pkg $failPkg
  }
  $leftover = $failPkg
  if (-not $leftover -and $stNow) { $leftover = [string]$stNow.package }
  $ok = Reboot-Emulator
  Finish-RebootReady -ContinueThisApk:$ContinueThisApk
  if ($leftover -and -not $ContinueThisApk) { Remove-TargetPackage $leftover | Out-Null }
  if (-not $ok) { Write-Host "NEXT_APK_BLOCKED reboot wait failed" }
  return $ok
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

function Test-PackageInstalled([string]$Pkg) {
  if (-not $Pkg) { return $false }
  $p = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "pm", "path", $Pkg)
  return ($p -match "package:")
}

function Remove-TargetPackage([string]$Pkg) {
  if (-not $Pkg) {
    Write-Host "UNINSTALL skip: empty package"
    return $false
  }
  $keep = @("com.capturecli", "io.github.huskydg.magisk", "com.topjohnwu.magisk", "android")
  if ($keep -contains $Pkg) {
    Write-Host "UNINSTALL refuse keep-package $Pkg"
    return $false
  }
  Write-Host "UNINSTALL begin $Pkg"
  Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "am", "force-stop", $Pkg) | Out-Null
  $adbOut = Invoke-AdbTimeout -Ms 20000 -CmdArgs @("uninstall", $Pkg)
  Write-Host "adb uninstall: $adbOut"
  if ($LdConsole) {
    Write-Host "ldconsole uninstallapp $Pkg"
    Write-Host (Invoke-ProcTimeout -FilePath $LdConsole -Ms 30000 -CmdArgs @("uninstallapp", "--index", "$LdIndex", "--packagename", $Pkg))
  }
  Start-Sleep 2
  if (Test-PackageInstalled $Pkg) {
    Write-Host "UNINSTALL_STILL_PRESENT $Pkg"
    return $false
  }
  Write-Host "UNINSTALL_OK $Pkg"
  return $true
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
  $needStart = $true
  foreach ($l in $listening) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($l.OwningProcess)" -ErrorAction SilentlyContinue
    $cmd = [string]$p.CommandLine
    if ($cmd -match "dump_urls\.py") {
      Write-Host "mitmdump already dumping URLs pid=$($l.OwningProcess)"
      $needStart = $false
    } else {
      Write-Host "killing non-dump listener pid=$($l.OwningProcess)"
      Stop-Process -Id $l.OwningProcess -Force -ErrorAction SilentlyContinue
    }
  }
  if (-not $needStart) { return }
  Start-Sleep 1
  if (-not $MitmDump) { Write-Host "WARN: mitmdump not found"; return }
  Start-Process -FilePath $MitmDump -ArgumentList @("-s", $py, "--listen-host", "127.0.0.1", "--listen-port", "8080", "-q") -WindowStyle Minimized | Out-Null
  Start-Sleep 2
  Write-Host "started mitmdump + dump_urls.py"
}

function Invoke-DumpXml {
  param([string]$LocalPath)
  $remote = "/sdcard/_capturecli_ui.xml"
  $rm = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "rm", "-f", $remote)
  if (Test-TextLooksHung $rm) { return @{ Hung = $true; Text = $rm } }
  $dump = Invoke-AdbTimeout -Ms 25000 -CmdArgs @("shell", "uiautomator", "dump", $remote)
  Write-Host $dump
  if (Test-TextLooksHung $dump) { return @{ Hung = $true; Text = $dump } }
  $pull = Invoke-AdbTimeout -Ms 15000 -CmdArgs @("pull", $remote, $LocalPath)
  Write-Host $pull
  if (Test-TextLooksHung $pull) { return @{ Hung = $true; Text = $pull } }
  return @{ Hung = $false; Ok = (Test-Path $LocalPath) }
}

function Invoke-Shot {
  param([string]$LocalPath)
  $remote = "/sdcard/_capturecli_shot.png"
  $cap = Invoke-AdbTimeout -Ms 15000 -CmdArgs @("shell", "screencap", "-p", $remote)
  if (Test-TextLooksHung $cap) { return @{ Hung = $true; Text = $cap } }
  $pull = Invoke-AdbTimeout -Ms 15000 -CmdArgs @("pull", $remote, $LocalPath)
  Write-Host $pull
  if (Test-TextLooksHung $pull) { return @{ Hung = $true; Text = $pull } }
  return @{ Hung = $false; Ok = (Test-Path $LocalPath) }
}

function Assert-NotHungDump {
  param($Result, [string]$Context)
  if ($Result -and $Result.Hung) {
    Recover-FromHang -Reason "$Context $($Result.Text)" | Out-Null
    throw "HUNG_REBOOTED during $Context; prepare the NEXT apk"
  }
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
    Ensure-CsvHeader
    $apkMb = [math]::Round((Get-Item -LiteralPath $Apk).Length / 1MB, 2)
    if ($MaxMb -gt 0 -and $apkMb -ge $MaxMb) {
      Write-Host "WARN: MaxMb=$MaxMb is set but size skip is disabled by policy; still installing mb=$apkMb"
    }
    Ensure-MitmUrls
    Invoke-AdbTimeout -Ms 8000 -CmdArgs @("connect", $Serial) | Out-Null
    $pkg = Get-PackageName $Apk
    if (-not $pkg) { throw "parse package failed" }
    $name = [IO.Path]::GetFileName($Apk)
    Write-Host "package=$pkg name=$name mb=$apkMb"
    Invoke-AdbTimeout -Ms 8000 -CmdArgs @("connect", $Serial) | Out-Null

    $pre = Get-EmulatorHealth
    if (-not $pre.Ok) {
      Write-Host "EMU_HUNG at prepare start — reboot then continue THIS apk"
      Recover-FromHang -Reason "before-prepare $($pre.Reason)" -ContinueThisApk | Out-Null
      $pre = Get-EmulatorHealth
      if (-not $pre.Ok) { throw "EMU_STILL_HUNG after reboot: $($pre.Reason)" }
    }

    Copy-Item -LiteralPath $Apk $TmpApk -Force
    Remove-TargetPackage $pkg | Out-Null
    Start-Sleep 2

    $inst = ""
    if (Wait-PackageManager) {
      Write-Host "adb install -r -g (ASCII temp)"
      $inst = Invoke-AdbTimeout -Ms 180000 -CmdArgs @("install", "-r", "-g", $TmpApk)
      Write-Host $inst
    } else {
      $inst = "TIMEOUT pm not ready"
      Write-Host $inst
    }
    if ($inst -notmatch "Success") {
      $health = Get-EmulatorHealth
      $looksHung = (Test-TextLooksHung $inst) -or (-not $health.Ok)
      if ($looksHung) {
        Recover-FromHang -Reason "install hung adb=$($inst.Trim()) health=$($health.Reason)" -FailCurrentApk | Out-Null
        throw "HUNG_REBOOTED do not retry this apk; prepare the NEXT apk"
      }
      if (-not $LdConsole) { throw "install failed and ldconsole.exe not found: $inst" }
      Write-Host "adb install failed but emulator alive; fallback ldconsole installapp index=$LdIndex (120s cap)"
      $ldOut = Invoke-ProcTimeout -FilePath $LdConsole -Ms 120000 -CmdArgs @("installapp", "--index", "$LdIndex", "--filename", $TmpApk)
      Write-Host $ldOut
      Start-Sleep 5
      $health2 = Get-EmulatorHealth
      if ((Test-TextLooksHung $ldOut) -or (-not $health2.Ok)) {
        Recover-FromHang -Reason "ldconsole install hung ld=$($ldOut.Trim()) health=$($health2.Reason)" -FailCurrentApk | Out-Null
        throw "HUNG_REBOOTED do not retry this apk; prepare the NEXT apk"
      }
      $pathCheck = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "pm", "path", $pkg)
      if ($pathCheck -notmatch "package:") {
        Remove-TargetPackage $pkg | Out-Null
        throw "install failed (adb+ldconsole): pkg not on device. adb=$inst ld=$ldOut"
      }
      $inst = "Success"
    }
    if (-not (Test-PackageInstalled $pkg)) {
      $health = Get-EmulatorHealth
      if (-not $health.Ok) {
        Recover-FromHang -Reason "installed but pm dead $($health.Reason)" -FailCurrentApk | Out-Null
        throw "HUNG_REBOOTED do not retry this apk; prepare the NEXT apk"
      }
      throw "install reported success but pm path missing for $pkg"
    }
    Write-Host "installed OK"

    Set-Content $UrlsFile "" -Encoding UTF8
    Invoke-AdbTimeout -Ms 8000 -CmdArgs @("reverse", "--remove-all") | Out-Null
    Write-Host (Invoke-AdbTimeout -Ms 8000 -CmdArgs @("reverse", "tcp:8080", "tcp:8080"))

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
    if ($status -eq "TIMEOUT" -or (Test-TextLooksHung $status)) {
      $h = Get-EmulatorHealth
      if (-not $h.Ok) {
        Recover-FromHang -Reason "capture-start $($h.Reason)" -FailCurrentApk | Out-Null
        throw "HUNG_REBOOTED do not retry this apk; prepare the NEXT apk"
      }
    }

    Write-Host "ldconsole runapp $pkg"
    Write-Host (Invoke-ProcTimeout -FilePath $LdConsole -Ms 30000 -CmdArgs @("runapp", "--index", "$LdIndex", "--packagename", $pkg))
    Write-Host "waiting ${WaitSec}s then dump XML + screenshot..."
    Start-Sleep $WaitSec

    $safe = ($name -replace '[^\w\.-]', '_')
    $round = 1
    $xml = Join-Path $OutDir ("{0}.r{1}.ui.xml" -f $safe, $round)
    $png = Join-Path $OutDir ("{0}.r{1}.png" -f $safe, $round)
    Assert-NotHungDump (Invoke-DumpXml $xml) "prepare-dump"
    Assert-NotHungDump (Invoke-Shot $png) "prepare-shot"
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
    Assert-NotHungDump (Invoke-DumpXml $xml) "dump"
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
    Assert-NotHungDump (Invoke-Shot $png) "shot"
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
    Assert-NotHungDump (Invoke-DumpXml $xml) "dumpshot-xml"
    Assert-NotHungDump (Invoke-Shot $png) "dumpshot-png"
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
    $r = Invoke-AdbTimeout -Ms 10000 -CmdArgs @("shell", "input", "tap", "$X", "$Y")
    Write-Host $r
    if (Test-TextLooksHung $r) {
      $h = Get-EmulatorHealth
      if (-not $h.Ok) {
        Recover-FromHang -Reason "tap $($h.Reason)" | Out-Null
        throw "HUNG_REBOOTED during tap; prepare the NEXT apk"
      }
    }
    break
  }

  "swipe" {
    Write-Host "swipe ($X,$Y)->($X2,$Y2)"
    $r = Invoke-AdbTimeout -Ms 10000 -CmdArgs @("shell", "input", "swipe", "$X", "$Y", "$X2", "$Y2", "400")
    Write-Host $r
    if (Test-TextLooksHung $r) {
      $h = Get-EmulatorHealth
      if (-not $h.Ok) {
        Recover-FromHang -Reason "swipe $($h.Reason)" | Out-Null
        throw "HUNG_REBOOTED during swipe; prepare the NEXT apk"
      }
    }
    break
  }

  "key" {
    Write-Host (Invoke-AdbTimeout -Ms 10000 -CmdArgs @("shell", "input", "keyevent", $Key))
    break
  }

  "text" {
    $esc = $Text -replace ' ', '%s'
    $r = Invoke-AdbTimeout -Ms 15000 -CmdArgs @("shell", "input", "text", $esc)
    Write-Host $r
    if (Test-TextLooksHung $r) {
      $h = Get-EmulatorHealth
      if (-not $h.Ok) {
        Recover-FromHang -Reason "text $($h.Reason)" | Out-Null
        throw "HUNG_REBOOTED during text; prepare the NEXT apk"
      }
    }
    break
  }

  "back" {
    Write-Host (Invoke-AdbTimeout -Ms 10000 -CmdArgs @("shell", "input", "keyevent", "KEYCODE_BACK"))
    break
  }
  "home" {
    Write-Host (Invoke-AdbTimeout -Ms 10000 -CmdArgs @("shell", "input", "keyevent", "KEYCODE_HOME"))
    break
  }

  { $_ -in @("finish", "teardown") } {
    if ($Action -eq "finish") {
      Write-Host "NOTE: finish == teardown only; Agent must classify + record CSV"
    }
    $st = Get-State
    if (-not $st) { throw "no current.json — run prepare first" }
    Start-Sleep 2
    $urlCopy = Join-Path $OutDir ($st.safe + ".urls.txt")
    if (Test-Path $UrlsFile) { Copy-Item $UrlsFile $urlCopy -Force }
    Write-Host (Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "am", "broadcast", "-a", "com.capturecli.STOP", "-n", "com.capturecli/.CliReceiver"))
    $gone = Remove-TargetPackage ([string]$st.package)
    if (-not $gone) {
      Write-Host "WARN: teardown could not confirm uninstall of $($st.package)"
    }
    Write-Host "URLS_FILE=$urlCopy"
    Write-Host "CURRENT_JSON=$StateFile"
    if (Test-Path $urlCopy) {
      Write-Host "--- classify hint (Agent must judge & record) ---"
      python $ClassifyPy $urlCopy 2>&1 | Out-Host
    } else {
      Write-Host "WARN: no urls file; MITM empty — Agent may staticfail or record mitm_empty"
    }
    Write-Host "NEXT: model_ui.ps1 record -MainDomain ... -ValuableDomains ... -EvidenceIds ... -Status mitm|static|..."
    Write-Host "TEARDOWN_OK"
    break
  }

  "uninstall" {
    $pkg = $Package
    if (-not $pkg) {
      $st = Get-State
      if ($st) { $pkg = [string]$st.package }
    }
    if (-not $pkg) { throw "uninstall requires -Package or current.json" }
    Write-Host (Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "am", "broadcast", "-a", "com.capturecli.STOP", "-n", "com.capturecli/.CliReceiver"))
    $ok = Remove-TargetPackage $pkg
    if (-not $ok) { throw "UNINSTALL failed for $pkg" }
    break
  }

  "classify" {
    $target = $Apk
    if (-not $target) {
      $st = Get-State
      if ($st -and $st.safe) {
        $cand = Join-Path $OutDir ($st.safe + ".urls.txt")
        if (Test-Path $cand) { $target = $cand }
      }
    }
    if (-not $target -or -not (Test-Path -LiteralPath $target)) {
      if (Test-Path $UrlsFile) { $target = $UrlsFile }
    }
    if (-not $target -or -not (Test-Path -LiteralPath $target)) { throw "classify needs -Apk <urls.txt> or prior teardown urls" }
    python $ClassifyPy $target 2>&1 | Out-Host
    break
  }

  "record" {
    $st = Get-State
    $name = $ApkName
    $pkg = $Package
    if ($st) {
      if (-not $name) { $name = [string]$st.name }
      if (-not $pkg) { $pkg = [string]$st.package }
    }
    if (-not $name -and $Apk) { $name = [IO.Path]::GetFileName($Apk) }
    if (-not $name) { throw "record needs -ApkName or current.json / -Apk" }
    if (-not $MainDomain) { throw "record requires -MainDomain (Agent decision)" }
    if (-not $Status) { $Status = "mitm" }
    if ($null -eq $ValuableDomains) { $ValuableDomains = "" }
    if ($null -eq $EvidenceIds) { $EvidenceIds = "" }
    if ($null -eq $Notes) { $Notes = "" }
    if ($null -eq $AllHosts) { $AllHosts = "" }
    if (-not $AllHosts -and (Test-Path $UrlsFile)) {
      $stats = Get-HostStats $UrlsFile
      $AllHosts = (($stats | ForEach-Object { "$($_.Key)($($_.Value))" }) -join '; ')
    }
    Upsert-DomainRow -Name $name -Pkg $pkg -Main $MainDomain -Valuable $ValuableDomains `
      -Evidence $EvidenceIds -All $AllHosts -Stat $Status -Note $Notes
    break
  }

  "health" {
    $h = Get-EmulatorHealth
    if ($h.Ok) { Write-Host "EMU_OK" } else { Write-Host "EMU_HUNG $($h.Reason)" }
    break
  }

  "rebootemu" {
    $ok = Reboot-Emulator
    if ($ok) { Finish-RebootReady } else { Write-Host "NEXT_APK_BLOCKED reboot wait failed" }
    break
  }

  "recover" {
    Recover-Adb
    $stt = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("get-state")
    Write-Host "adb-state=$stt"
    Invoke-AdbTimeout -Ms 8000 -CmdArgs @("reverse", "--remove-all") | Out-Null
    Write-Host (Invoke-AdbTimeout -Ms 8000 -CmdArgs @("reverse", "tcp:8080", "tcp:8080"))
    $caOk = Invoke-AdbTimeout -Ms 8000 -CmdArgs @("shell", "ls", "/system/etc/security/cacerts/c8750f0d.0")
    Write-Host "ca-file=$caOk"
    if ($caOk -notmatch "c8750f0d") {
      Write-Host "CA missing after reboot — run: capture.ps1 ca"
    }
    Write-Host "RECOVER_OK"
    break
  }

  "installfail" {
    if (-not $Apk -or -not (Test-Path -LiteralPath $Apk)) { throw "installfail requires -Apk" }
    $note = if ($Notes) { $Notes } else { "install_failed (emulator alive or parse/zip error); no retry" }
    Write-InstallFailedRow -Note $note -Pkg $Package
    $h = Get-EmulatorHealth
    if (-not $h.Ok) {
      Recover-FromHang -Reason "installfail $($h.Reason)" | Out-Null
    } else {
      Write-Host "EMU_OK after install fail — prepare the NEXT apk (do not retry this one)"
    }
    break
  }

  "staticfail" {
    Write-Host "NOTE: staticfail aliases installfail (size skip removed)"
    & $PSCommandPath installfail -Apk $Apk -OutDir $OutDir -Serial $Serial -Package $Package `
      -MainDomain $MainDomain -ValuableDomains $ValuableDomains -EvidenceIds $EvidenceIds `
      -AllHosts $AllHosts -Notes $Notes
    break
  }
}

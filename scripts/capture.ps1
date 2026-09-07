# CaptureCli host-side CLI (skill-bundled, portable)
#   .\capture.ps1 ca
#   .\capture.ps1 mitm
#   .\capture.ps1 install-apk
#   .\capture.ps1 start <package>
#   .\capture.ps1 stop | status | pull

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("ca", "start", "stop", "status", "pull", "mitm", "install-apk")]
    [string]$Cmd,

    [Parameter(Position = 1)]
    [string]$Package = "com.android.settings",

    [string]$Adb = "",
    [string]$Serial = "127.0.0.1:5555",
    [string]$ProxyHost = "",
    [int]$ProxyPort = 8080,
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-Env.ps1")
$E = Resolve-SkillEnv -AdbExe $Adb -Serial $Serial -MitmDump ""
if (-not $E.Adb) { throw "adb.exe not found" }
if (-not $OutDir) { $OutDir = $E.OutDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$MitmDump = $E.MitmDump
$Har = Join-Path $OutDir ("capture_{0}.har" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$ClashDir = Join-Path $env:USERPROFILE "AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev"
$DnsCfg = Join-Path $ClashDir "dns_config.yaml"
$DnsBak = Join-Path $OutDir "dns_config.yaml.capturecli.bak"
$StateFile = Join-Path $OutDir "fakeip_state.txt"

function Adb {
    & $E.Adb -s $E.Serial @args
}

function Disable-HostFakeIp {
    if (-not (Test-Path $DnsCfg)) {
        Write-Host "WARN: Clash Verge dns_config.yaml not found; skip host fake-ip patch"
        return $false
    }
    $raw = Get-Content -Raw $DnsCfg
    if ($raw -notmatch "enhanced-mode:\s*fake-ip") {
        Write-Host "host DNS already not fake-ip"
        return $false
    }
    Copy-Item $DnsCfg $DnsBak -Force
    $new = $raw -replace "enhanced-mode:\s*fake-ip", "enhanced-mode: redir-host"
    Set-Content -Path $DnsCfg -Value $new -Encoding UTF8 -NoNewline
    Set-Content -Path $StateFile -Value "patched" -Encoding ASCII
    $p = Get-Process -Name "verge-mihomo" -ErrorAction SilentlyContinue
    if ($p) {
        Write-Host "reloading verge-mihomo to apply redir-host..."
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    Write-Host "host fake-ip temporarily disabled (redir-host). Will restore on stop."
    return $true
}

function Restore-HostFakeIp {
    if (-not (Test-Path $StateFile)) { return }
    if (-not (Test-Path $DnsBak)) {
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        return
    }
    Copy-Item $DnsBak $DnsCfg -Force
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    $p = Get-Process -Name "verge-mihomo" -ErrorAction SilentlyContinue
    if ($p) {
        Write-Host "restoring Clash Verge fake-ip; reloading verge-mihomo..."
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    Write-Host "host fake-ip restored"
}

function Test-FakeIpDns {
    $ping = Adb shell "ping -c 1 -W 2 example.com 2>&1" | Out-String
    return ($ping -match "\((198\.18\.\d+\.\d+)\)")
}

switch ($Cmd) {
    "mitm" {
        if (-not $MitmDump) { throw "mitmdump not found. pip install mitmproxy and ensure mitmdump is on PATH." }
        Write-Host "mitmdump 0.0.0.0:$ProxyPort  HAR=$Har"
        Write-Host "Keep this window open."
        & $MitmDump --listen-host 0.0.0.0 --listen-port $ProxyPort --set "hardump=$Har"
    }

    "ca" {
        $caDir = Join-Path $env:USERPROFILE ".mitmproxy"
        $pem = Join-Path $caDir "mitmproxy-ca-cert.pem"
        if (-not (Test-Path $pem)) {
            Write-Host "Generating mitmproxy CA via CertStore API..."
            python -c "from mitmproxy.certs import CertStore; from pathlib import Path; p=Path(r'$caDir'); p.mkdir(parents=True, exist_ok=True); CertStore.from_store(str(p), 'mitmproxy', 2048); print('ok')"
        }
        if (-not (Test-Path $pem)) { throw "CA not found: $pem" }

        $tmp = Join-Path $OutDir "mitmproxy-ca.pem"
        Copy-Item $pem $tmp -Force
        $hashPy = Join-Path $PSScriptRoot "android_ca_hash.py"
        $hash = (python $hashPy $tmp).Trim()
        if (-not $hash) { throw "failed to compute android ca hash" }
        $outCert = Join-Path $OutDir "$hash.0"
        Copy-Item $tmp $outCert -Force
        Write-Host "CA hash=$hash"

        Adb push $outCert "/data/local/tmp/$hash.0" | Out-Host
        $script = @"
set -e
HASH=$hash
mkdir -p /data/local/tmp/cacerts_work
cp -f /system/etc/security/cacerts/* /data/local/tmp/cacerts_work/ 2>/dev/null || true
cp -f /data/local/tmp/$hash.0 /data/local/tmp/cacerts_work/$hash.0
chmod 644 /data/local/tmp/cacerts_work/$hash.0
mount | grep -q ' /system/etc/security/cacerts ' || mount -t tmpfs tmpfs /system/etc/security/cacerts
cp -f /data/local/tmp/cacerts_work/* /system/etc/security/cacerts/
chmod 644 /system/etc/security/cacerts/*
ls -l /system/etc/security/cacerts/$hash.0
"@
        $localSh = Join-Path $OutDir "install_ca.sh"
        [IO.File]::WriteAllText($localSh, ($script -replace "`r`n", "`n"))
        Adb push $localSh /data/local/tmp/install_ca.sh | Out-Host
        Adb shell "su 0 sh /data/local/tmp/install_ca.sh" | Out-Host
        Write-Host "System CA injected (tmpfs). Re-run after emulator reboot."
    }

    "install-apk" {
        if (-not (Test-Path $E.CaptureCliApk)) { throw "assets/CaptureCli.apk missing" }
        $tmp = Join-Path $env:TEMP "skill_CaptureCli.apk"
        Copy-Item $E.CaptureCliApk $tmp -Force
        Adb install -r -g $tmp | Out-Host
    }

    "start" {
        if (-not $ProxyHost) { $ProxyHost = "127.0.0.1" }
        if (Test-FakeIpDns) {
            Write-Host "detected fake-ip DNS (198.18.x); patching Clash Verge -> redir-host"
            Disable-HostFakeIp | Out-Null
            Start-Sleep -Seconds 2
        } elseif (Get-Process -Name "verge-mihomo" -ErrorAction SilentlyContinue) {
            Disable-HostFakeIp | Out-Null
        }

        Adb reverse --remove-all 2>$null | Out-Null
        Adb reverse "tcp:$ProxyPort" "tcp:$ProxyPort" | Out-Host
        Write-Host "proxy=$ProxyHost`:$ProxyPort package=$Package (adb reverse enabled)"
        $listen = Get-NetTCPConnection -LocalPort $ProxyPort -State Listen -ErrorAction SilentlyContinue
        if (-not $listen) {
            Write-Host "WARN: port $ProxyPort not listening. Run: .\capture.ps1 mitm"
        }
        Adb shell am broadcast -a com.capturecli.START -n com.capturecli/.CliReceiver --es package $Package --es proxy "$ProxyHost`:$ProxyPort" | Out-Host
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep 1
            $status = (Adb shell "cat /sdcard/capturecli-status.txt 2>/dev/null" | Out-String).Trim()
            if ($status -match 'mode=(root-redirect|global-proxy)' -or $status -match '^error=') { break }
        }
        Adb shell "cat /sdcard/capturecli-status.txt 2>/dev/null" | Out-Host
    }

    "stop" {
        Adb shell am broadcast -a com.capturecli.STOP -n com.capturecli/.CliReceiver | Out-Host
        Adb shell "su 0 sh -c 'iptables -t nat -D OUTPUT -j CAPTURECLI 2>/dev/null; iptables -t nat -F CAPTURECLI 2>/dev/null; iptables -t nat -X CAPTURECLI 2>/dev/null; iptables -t nat -D OUTPUT -j CAPTURECLI_DNS 2>/dev/null; iptables -t nat -F CAPTURECLI_DNS 2>/dev/null; iptables -t nat -X CAPTURECLI_DNS 2>/dev/null; pkill -f \"gost -L redirect\" 2>/dev/null; settings delete global http_proxy'" | Out-Host
        Restore-HostFakeIp
        Adb shell "cat /sdcard/capturecli-status.txt 2>/dev/null" | Out-Host
    }

    "status" {
        Adb shell am broadcast -a com.capturecli.STATUS -n com.capturecli/.CliReceiver | Out-Host
        Adb shell "cat /sdcard/capturecli-status.txt 2>/dev/null" | Out-Host
        Adb shell "su 0 iptables -t nat -S CAPTURECLI 2>/dev/null" | Out-Host
        Adb shell "su 0 pidof gost 2>/dev/null" | Out-Host
    }

    "pull" {
        New-Item -ItemType Directory -Force -Path (Join-Path $OutDir "device") | Out-Null
        Adb pull /sdcard/capturecli-status.txt (Join-Path $OutDir "device/status.txt") 2>$null
        Write-Host "OutDir: $OutDir"
    }
}

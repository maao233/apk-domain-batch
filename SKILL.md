---
name: apk-domain-batch
description: >-
  便携的雷电/ADB + CaptureCli 批量 APK 主域名分析。自带 CaptureCli.apk、platform-tools(adb)
  与 PS 脚本；Magisk 管理端 APK 与 mitmproxy 需本机按 README 准备。首次探测配置后逐个安装抓包，
  输出 domains.csv。适用于任意能执行本目录脚本的 Agent（不限 Cursor）。
  在用户提到 APK 批量域名、主域名分析、CaptureCli、apk_crack、数证杯 APK 域名时使用。
---

# APK 批量主域名分析（便携 skill）

原理与人类准备见 [README.md](README.md)。禁止写死某台机器盘符；路径相对本目录；adb 优先 `tools/platform-tools`。  
**Quick Start 由 Agent 执行**（按 README「Quick Start（给 Agent）」），不要只把命令甩给用户。

## 目录结构

```text
apk-domain-batch/
  SKILL.md
  README.md / THIRD_PARTY.md / LICENSE
  assets/
    CaptureCli.apk
    Magisk.apk          # 本地自备，不入库
  tools/
    platform-tools/     # 自带 adb.exe + NOTICE.txt
  scripts/
    ...
  out/
```

## 自带 vs 需安装

| 组件 | 是否自带 | 说明 |
|------|----------|------|
| `adb` / platform-tools | **是** `tools/platform-tools/` | 探测时优先使用 |
| `CaptureCli.apk` | **是** | 经 `%TEMP%` 英文路径安装 |
| `Magisk.apk` | **否（本地自备）** | GPL/再分发不合规，见 README / THIRD_PARTY；放到 `assets/Magisk.apk` |
| PS 脚本 | **是** | `scripts/` |
| **mitmproxy / mitmdump** | **否** | 见下方「安装 mitmproxy」 |
| 雷电 `ldconsole` | 否 | PATH 或常见安装目录探测 |
| `aapt` | 否 | SDK build-tools 或雷电目录旁 |
| Python 3 | 否 | 装 mitmproxy / 跑 `android_ca_hash.py` 需要 |

`Magisk.apk`  alone 不能把未 root 镜像变成 root。

---

## 安装 mitmproxy（各机必做一次）

mitmproxy 依赖 Python，体积与版本组合多，**不打进 skill**。按下面安装即可。

### 1. 安装 Python 3.10–3.12（推荐）

- 官网：https://www.python.org/downloads/  
- 勾选 **Add python.exe to PATH**  
- 验证：

```powershell
python --version
```

> 过新的 Python（如 3.14）可能暂时没有 mitmproxy 轮子，请用 3.11/3.12。

### 2. 安装 mitmproxy

```powershell
python -m pip install -U pip
python -m pip install mitmproxy
```

验证：

```powershell
mitmdump --version
# 或
python -m mitmproxy.tools.dump --version
```

`mitmdump.exe` 通常在：

- `%USERPROFILE%\AppData\Roaming\Python\Python3xx\Scripts\mitmdump.exe`  
- 或 venv 的 `Scripts\mitmdump.exe`

确保该 `Scripts` 在 PATH，或让 `Resolve-Env.ps1` 能扫到（已会搜 Roaming\Python）。

### 3. 生成 CA（首次）

```powershell
# 任选：先跑一次 mitmdump 会生成 ~/.mitmproxy
mitmdump --listen-port 8080
# Ctrl+C 停掉后，证书在：
#   %USERPROFILE%\.mitmproxy\mitmproxy-ca-cert.pem
```

再用 skill 注入进模拟器：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>/scripts/capture.ps1" ca
```

### 4. 日常抓包用法

**终端 A（保持开着）：**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>/scripts/capture.ps1" mitm
```

或直接：

```powershell
mitmdump --listen-host 127.0.0.1 --listen-port 8080
```

**终端 B：** 跑 `setup_first_run.ps1` / `analyze_one_by_one.ps1`（脚本会 `adb reverse tcp:8080`）。

无 mitmproxy 时：分析脚本仍可跑，但 MITM URL 为空，主域名走 **static** 兜底。

---

## 阶段 A：首次使用

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>/scripts/setup_first_run.ps1"
```

可选：`-Serial 127.0.0.1:5555` `-LdIndex 0` `-AdbExe` `-LdConsole`

流程：探测 → 启雷电 → 装 Magisk/CaptureCli → `capture.ps1 ca` → 冒烟 START。  
Magisk 对 `com.capturecli` 选**永久允许**。

## 阶段 B：分析

```powershell
powershell -File "<SKILL>/scripts/build_apk_list.ps1" -ApkDir "<apk目录>"
# 终端 A: capture.ps1 mitm
powershell -File "<SKILL>/scripts/analyze_one_by_one.ps1" `
  -ListFile "<SKILL>/out/apk_unique_list.txt" `
  -OutDir "<SKILL>/out/run1" `
  -StartIndex 0 -Count 22 -DumpWaitSec 10 -AfterTapSec 12
```

硬规则：**一次只装一个 App，分析完卸载再下一个。**

## 阶段 C：收尾

产出 `<OutDir>/domains.csv`（`mitm` / `static` / 失败码）。核对行数、修正误主域、确认目标包已卸。

## Agent 硬规则

- 路径相对 skill 或用户传入目录，禁止写死他人机器盘符  
- 优先用 `tools/platform-tools/adb.exe`  
- `adb install` 经 `%TEMP%` ASCII 名  
- 模拟器重启后重做 `capture.ps1 ca`  
- mitmproxy 未装时明确告知用户按本文安装，勿假装已自带  

更多故障见 [reference.md](reference.md)。

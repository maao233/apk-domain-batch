# apk-domain-batch

Cursor Agent Skill：在 **雷电模拟器 + ADB + CaptureCli** 上批量分析 APK **主域名**，输出 `domains.csv`。

一次只安装一个 App → 抓包 / 静态兜底 → 卸载 → 下一个。

## Compliance summary（上传前必读）

| 资产 | 是否进仓库 | 原因 |
|------|------------|------|
| `tools/platform-tools/` (adb) | **是** | Google Platform-Tools，Apache-2.0，保留 `NOTICE.txt` |
| `assets/CaptureCli.apk` | **是** | 本项目抓包辅助 APK（内嵌 [gost](https://github.com/go-gost/gost)） |
| `scripts/` | **是** | MIT |
| `assets/Magisk.apk` | **否** | Magisk/Kitsune 基于 **GPL-3.0**；二进制再分发不合规且有非官方镜像风险 |
| mitmproxy | **否** | 用 pip 安装（见下） |

详情见 [THIRD_PARTY.md](THIRD_PARTY.md)。

**请自行下载 Magisk**，放到 `assets/Magisk.apk`（仅本地，勿提交）：

- 官方 Magisk：https://github.com/topjohnwu/Magisk/releases  
- Kitsune（非官方，自担风险）：仅从维护者官方渠道获取；**不要**从不明网盘下载

## Layout

```text
apk-domain-batch/
  SKILL.md                 # Agent 工作流
  README.md                # 本文件
  THIRD_PARTY.md           # 合规说明
  LICENSE                  # MIT（脚本与文档）
  assets/
    CaptureCli.apk         # 已包含
    Magisk.apk             # 本地自备，gitignore
  tools/
    platform-tools/        # 自带 adb
  scripts/
    setup_first_run.ps1
    capture.ps1
    analyze_one_by_one.ps1
    build_apk_list.ps1
    Resolve-Env.ps1
    android_ca_hash.py
```

## Requirements

- Windows + PowerShell
- 已 root 的雷电模拟器（或等价 Magisk 镜像）
- Python 3.10–3.12 + mitmproxy（见下）
- 本 skill 自带 `adb`；`aapt` / `ldconsole` 自动探测

## Install mitmproxy

```powershell
python --version          # 推荐 3.11 / 3.12
python -m pip install -U pip
python -m pip install mitmproxy
mitmdump --version
```

## Quick start

```powershell
# 0) 克隆后：自行下载 Magisk APK → assets/Magisk.apk

# 1) 首次配置（探测环境、装 CaptureCli、注入 CA、冒烟）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_first_run.ps1

# 2) Magisk 中对 com.capturecli 永久允许 root

# 3) 终端 A：MITM
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\capture.ps1 mitm

# 4) 终端 B：去重列表 + 分析
powershell -File .\scripts\build_apk_list.ps1 -ApkDir "D:\path\to\apks"
powershell -File .\scripts\analyze_one_by_one.ps1 `
  -ListFile .\out\apk_unique_list.txt `
  -OutDir .\out\run1 `
  -Count 22
```

输出：`out/run1/domains.csv`（`mitm` / `static`）。

## Agent

将本目录放到 Cursor skills（如 `~/.cursor/skills/apk-domain-batch`），Agent 按 `SKILL.md` 执行。路径一律相对本仓库，禁止写死他人机器盘符。

## Disclaimer

仅用于你有权分析的样本与授权实验环境。Magisk/root 有变砖与安全风险，后果自负。

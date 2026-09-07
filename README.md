# apk-domain-batch

在 **已 root 的 Android 模拟器（推荐雷电）** 上，对一批 APK **逐个**安装、抓取业务主域名，并写出 `domains.csv`。  
本仓库是可被任意 Agent（Cursor / Claude Code / Codex / 自建 Agent 等）加载的技能包：脚本与资产相对本目录，不绑定某一 IDE。

硬规则：**同一时刻只装一个目标 App → 分析 → 卸载 → 再下一个。**

---

## 技术原理

目标是尽量拿到「真实业务域名」，而不是只靠 APK 字符串盲猜。整体是 **主机 MITM + 设备侧按 UID 透明重定向**。

```text
┌──────────────────────── Host (Windows) ────────────────────────┐
│  mitmdump :8080                                                │
│       ▲                                                        │
│       │  adb reverse tcp:8080 → device:8080                    │
└───────┼────────────────────────────────────────────────────────┘
        │
┌───────┼──────── Device (Magisk root) ──────────────────────────┐
│  CaptureCli (com.capturecli)                                   │
│    · 查目标 App UID                                            │
│    · 写 iptables/nft 规则：仅该 UID 的 TCP → 本机 gost         │
│    · gost 把流量转到 127.0.0.1:8080（经 reverse 到主机）       │
│  系统 CA：把 mitmproxy CA 挂进 /system/etc/security/cacerts/   │
│           （tmpfs 覆盖；模拟器重启后需重做）                     │
└────────────────────────────────────────────────────────────────┘
```

### 为什么要 root + CaptureCli

| 方式 | 问题 |
|------|------|
| 仅全局 HTTP 代理 | 很多 App 不读系统代理 / 直连 IP |
| VPN 抓包 App | 与目标 App 并存时权限与稳定性差，批量难自动化 |
| 无 CA 的 HTTPS | 只能看到 SNI/IP，无法看明文 Host（且 pinning 仍可能失败） |

CaptureCli 在 **root** 下按 **应用 UID** 做透明转发（内嵌 [gost](https://github.com/go-gost/gost)），只影响当前样本，卸掉样本后规则随之清掉。主机侧始终跑 `mitmdump`，证书固定、日志好收。

### 域名怎么定

对每个 APK：

1. **MITM 优先**：从 mitm 流量里收集 Host / SNI，过滤广告、CDN、系统域后选「主域名」  
2. **Static 兜底**：MITM 为空（证书 pinning、无明文流量等）时，从 APK 内嵌字符串提取候选域名再择优  
3. CSV 字段：`apk,package,main_domain,all_hosts,status`（`status` 为 `mitm` / `static` / 失败码）

### 关键路径与状态

- 启动/停止：ADB broadcast → CaptureCli 前台服务写脚本再 `su` 执行（避免长 `su -c` 被 Magisk 截断、Broadcast ANR）  
- 状态文件：`/sdcard/capturecli-status.txt`  
  - 成功示例：`mode=root-redirect ... gost=up chain=ok`  
  - 停止：`mode=stopped`

---

## 环境要求

| 项 | 说明 |
|----|------|
| OS | Windows + PowerShell |
| 模拟器 | 已 root（Magisk / Kitsune 等）；雷电常用 `127.0.0.1:5555` |
| Python | 3.10–3.12 + `pip install mitmproxy`（**不**打进仓库） |
| Magisk 管理端 APK | **自行下载**到 `assets/Magisk.apk`（GPL，仓库不附带，见 [THIRD_PARTY.md](THIRD_PARTY.md)） |
| 自带 | `tools/platform-tools/adb.exe`、`assets/CaptureCli.apk`、全部 `scripts/` |

可选：本机 Android SDK 的 `aapt`、雷电 `ldconsole`（脚本会探测）。

---

## 目录

```text
apk-domain-batch/
  SKILL.md              # Agent 执行规范（优先读）
  README.md             # 原理与用法（本文件）
  THIRD_PARTY.md        # 第三方合规
  assets/CaptureCli.apk
  assets/Magisk.apk     # 本地自备，gitignore
  tools/platform-tools/ # adb + NOTICE.txt
  scripts/
    Resolve-Env.ps1     # 探测 adb / mitmdump / 雷电等
    setup_first_run.ps1 # 首次：装 APK、注入 CA、冒烟
    capture.ps1         # ca | mitm | start/stop 辅助
    build_apk_list.ps1  # APK 目录 MD5 去重
    analyze_one_by_one.ps1
    android_ca_hash.py
  out/                  # 运行产物（默认不入库）
```

路径一律相对本仓库根目录；**禁止写死他人机器盘符**。含非 ASCII 的 APK 路径安装前会拷到 `%TEMP%`。

---

## 人类：一次性准备

1. 克隆本仓库  
2. 下载 [Magisk Releases](https://github.com/topjohnwu/Magisk/releases) 的管理端 APK，保存为 `assets/Magisk.apk`  
3. 安装 Python 3.11/3.12，并执行：

```powershell
python -m pip install -U pip mitmproxy
mitmdump --version
```

4. 启动已 root 的模拟器，ADB 能 `adb devices` 看到设备  
5. 将后续批量工作交给 Agent（见下），或自行按 `SKILL.md` 跑脚本  

首次在 Magisk 里对 **`com.capturecli` 勾选永久允许 root**。模拟器 **重启后** 必须重跑 CA 注入（`capture.ps1 ca`）。

---

## Quick Start（给 Agent）

把本目录当作 skill / 工具包挂载后，**由 Agent 按顺序执行**（不要只把命令丢给用户）。用户只需提供：APK 目录路径、可选设备 serial。

### 0. 读规范

打开并遵循同目录 [`SKILL.md`](SKILL.md)。输出与排错见 [`reference.md`](reference.md)。

### 1. 定位根目录

设 `$ROOT` = 本仓库绝对路径（Agent 自行解析，勿臆造盘符）。确认存在：

- `$ROOT/assets/CaptureCli.apk`  
- `$ROOT/tools/platform-tools/adb.exe`  
- `$ROOT/assets/Magisk.apk`（若缺失：提示用户按上文下载，勿跳过合规说明）

### 2. 检查 mitmproxy

```powershell
mitmdump --version
```

失败则按「人类：一次性准备」安装后再继续；未装时仍可分析，但主域名多半只能走 **static**。

### 3. 首次环境（每台机器 / 新镜像一次）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT\scripts\setup_first_run.ps1"
```

确认 `/sdcard/capturecli-status.txt` 冒烟为 `root-redirect` 且 `gost=up`。若 Magisk 弹授权，引导用户点永久允许后重试 START。

### 4. 开 MITM（长驻）

在**独立会话**保持运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT\scripts\capture.ps1" mitm
```

### 5. 构建去重列表并批量分析

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT\scripts\build_apk_list.ps1" -ApkDir "<用户APK目录>"

powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT\scripts\analyze_one_by_one.ps1" `
  -ListFile "$ROOT\out\apk_unique_list.txt" `
  -OutDir "$ROOT\out\run1" `
  -StartIndex 0 -Count <N> -DumpWaitSec 10 -AfterTapSec 12
```

### 6. 交付

- 主产物：`$ROOT/out/run1/domains.csv`  
- 向用户说明：`mitm` vs `static` 比例、失败行、是否需重做 CA  
- 确认设备上目标包已卸载，CaptureCli 可 STOP  

### Agent 约束

- 一次只装一个样本；禁止并行多包安装「赶进度」  
- 优先使用 `$ROOT/tools/platform-tools/adb.exe`  
- `adb install` 经 `%TEMP%` ASCII 文件名  
- 不提交、不上传 `assets/Magisk.apk`  
- 本技能不限定 Cursor：任何能跑 PowerShell、读 `SKILL.md` 的 Agent 均可驱动  

---

## 合规摘要

| 资产 | 是否入库 | 说明 |
|------|----------|------|
| platform-tools | 是 | Apache-2.0，保留 `NOTICE.txt` |
| CaptureCli.apk | 是 | 内嵌 gost，见 THIRD_PARTY |
| Magisk.apk | **否** | GPL-3.0，用户自备 |
| mitmproxy | 否 | pip 安装 |

详情：[THIRD_PARTY.md](THIRD_PARTY.md)。仅用于你有权分析的样本与授权环境。

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
      Resolve-Env.ps1 / setup_first_run.ps1 / capture.ps1 / build_apk_list.ps1
      model_ui.ps1          # 装包·dump·点选原语·teardown·record
      classify_capture.py   # 抓包提示 JSON（Agent 研判用）
      summarize_ui.py
      analyze_one_by_one.ps1  # 遗留兜底，默认不用
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

把本目录当作 skill / 工具包挂载后，**由 Agent 按 `SKILL.md` 单包驱动**（不要丢一整段 PS 批量点选/定域）。用户只需提供 APK 目录与可选 serial。

### 分工

- **PS**：`prepare` 装包+开抓+dump；`tap` 原语；`teardown`/`uninstall` **必须卸掉目标包并打印 UNINSTALL_OK**
- **Agent**：每个 APK **停下来读 PNG 截图** 再 `tap`（禁止 foreach+正则批量点）；`record` 写 CSV；确认卸载后再下一包

### 最短流程

```powershell
# 去重列表（体积只写入 report，不跳过安装）
powershell -File "$ROOT\scripts\build_apk_list.ps1" -ApkDir "<用户APK目录>"

# 终端 A 长驻 mitm
powershell -File "$ROOT\scripts\capture.ps1" mitm

# 每个 APK（Agent 一次只做一个；必须 Read PNG 再 tap；点击 ≥ 约 1 分钟）：
powershell -File "$ROOT\scripts\model_ui.ps1" prepare -Apk "<apk>" -OutDir "$ROOT\out\run_model" -WaitSec 10
# 安装失败或雷电重启：recover + capture.ps1 ca + installfail，然后下一个
# → Agent 打开 PNG= 截图看画面，再：
powershell -File "$ROOT\scripts\model_ui.ps1" tap -X <x> -Y <y> -OutDir "$ROOT\out\run_model"
powershell -File "$ROOT\scripts\model_ui.ps1" text -Text "13800138000" -OutDir "$ROOT\out\run_model"
powershell -File "$ROOT\scripts\model_ui.ps1" dumpshot -OutDir "$ROOT\out\run_model"
powershell -File "$ROOT\scripts\model_ui.ps1" teardown -OutDir "$ROOT\out\run_model"
# 必须出现 UNINSTALL_OK；没有则 uninstall -Package <pkg>
# → 看 classify JSON，再：
powershell -File "$ROOT\scripts\model_ui.ps1" record -OutDir "$ROOT\out\run_model" `
  -MainDomain "业务主域" `
  -ValuableDomains "bucket.oss-accelerate.aliyuncs.com [aliyun-oss-accelerate]; ..." `
  -EvidenceIds "aliyun_bucket=...; object=....dat" `
  -Status mitm
```

CSV `status`：`mitm` / `mitm_empty` / `static` / `install_failed`。不要用体积当失败码。  
测试账号、点击满 1 分钟、重启后恢复：[`reference.md`](reference.md)。`analyze_one_by_one.ps1` 仅遗留兜底，默认不用。

### Agent 约束

- 一次只装一个样本；**本包 UNINSTALL_OK（或 install_failed）后才能装下一个**  
- 每个 APK **必须读截图再点**，禁止 foreach+正则批量 tap；有登录就填 reference 账号并点提交；点击 ≥ 约 1 分钟  
- 不按体积跳过；装失败 → `install_failed` 下一包；卡死 → 自动重启后下一包（不重试该包）  
- 优先 `$ROOT/tools/platform-tools/adb.exe`；安装经 `%TEMP%` ASCII  
- 不提交 `assets/Magisk.apk`  
- 不限定 Cursor  

---

## 合规摘要

| 资产 | 是否入库 | 说明 |
|------|----------|------|
| platform-tools | 是 | Apache-2.0，保留 `NOTICE.txt` |
| CaptureCli.apk | 是 | 内嵌 gost，见 THIRD_PARTY |
| Magisk.apk | **否** | GPL-3.0，用户自备 |
| mitmproxy | 否 | pip 安装 |

详情：[THIRD_PARTY.md](THIRD_PARTY.md)。仅用于你有权分析的样本与授权环境。

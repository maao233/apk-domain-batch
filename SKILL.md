---
name: apk-domain-batch
description: >-
  便携的雷电/ADB + CaptureCli 批量 APK 主域名分析。自带 CaptureCli.apk、platform-tools(adb)
  与 PS 脚本；Magisk 管理端 APK 与 mitmproxy 需本机按 README 准备。
  PS 只负责安装/开抓包/dump；Agent 负责点选、报错处理、域名研判与 CSV 落盘。
  适用于任意能执行本目录脚本的 Agent（不限 Cursor）。
  在用户提到 APK 批量域名、主域名分析、CaptureCli、apk_crack、数证杯 APK 域名时使用。
---

# APK 批量主域名分析（便携 skill）

原理与人类准备见 [README.md](README.md)。点击/登录/装包失败见 [reference.md](reference.md)。  
禁止写死某台机器盘符；路径相对本目录；adb 优先 `tools/platform-tools`。

## 职责划分（强制）

| 角色 | 负责 | 禁止 |
|------|------|------|
| **PowerShell (`model_ui.ps1`)** | 装包、CaptureCli START、dump XML/截图、暴露 `tap`/`text` 原语、**teardown 必须卸包** | 禁止 `foreach` 批量点选；禁止用 CLICKABLES 正则自动点登录；禁止自己定主域写 CSV |
| **Agent（本模型）** | **每个 APK 单独一轮**：读 **PNG 截图** 决定点哪里，再 `tap`/`text`；处理断链/重启；研判抓包 `record`；确认包已卸载 | 禁止让用户点屏；禁止把整目录丢给 `analyze_one_by_one.ps1`；禁止用一段 PS 循环替代看图 |

硬规则：**一次只装一个 App → Agent 读图点击（≥约 1 分钟）→ teardown（确认卸载）→ record → 下一个。**

**禁止按体积跳过安装。** 装不上就 `install_failed`，**不要重试同一包**。若安装/点击时模拟器卡死（Broken pipe、adb TIMEOUT、`pm` 无响应）：脚本会检出 `HUNG_DETECTED`，自动 `rebootemu`+注 CA，打出 `NEXT_APK_READY`，然后分析**下一个** APK。

---

## 严禁的错误做法

```powershell
# 禁止：foreach 列表 + 正则从 CLICKABLES 抠坐标批量 tap
foreach ($apk in $list) {
  prepare ...
  if ($line -match '登录') { tap ... }
  teardown ...
}
# 禁止：因 APK 体积大就不装，直接 staticfail / too_large
```

正确：每个 APK 停下来，Read `PNG=` 截图，按画面点。登录页要填号并点注册/登录。下一包必须等本包 `UNINSTALL_OK`，或本包装失败已 `install_failed`。

---

## 阶段 A：环境

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>/scripts/setup_first_run.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>/scripts/capture.ps1" mitm
powershell -File "<SKILL>/scripts/build_apk_list.ps1" -ApkDir "<apk目录>"
```

列表含 **全部** 去重 APK（体积只写进 `apk_size_report.csv` 供参考，不作为跳过条件）。

---

## 阶段 B：单包（Agent 看图驱动）

对列表 **一次只处理一行**：

### 1) PS：安装 + 开抓 + dump

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>/scripts/model_ui.ps1" prepare `
  -Apk "<apk>" -OutDir "<SKILL>/out/run_model" -WaitSec 10
```

成功：`READY_FOR_MODEL_TAP`，记下 `PNG=` `XML=`。

**安装失败 / 装完 ADB 掉线 / 雷电卡住：**

- 失败的包**不要再 `prepare`**（装不上的会一直装不上）。
- `prepare`/`tap`/`dumpshot` 若检出卡死：会打印 `HUNG_DETECTED` → 关开雷电 → 注 CA → `NEXT_APK_READY`。Agent 看到后立刻 **prepare 下一个 APK**。
- aapt 解析失败 / zip 损坏：模拟器通常还活着，直接 `installfail`，**不用重启**，做下一个。
- 也可单独跑：`model_ui.ps1 health`（`EMU_OK` / `EMU_HUNG`）、`rebootemu`（关开并注 CA）。

### 2) Agent：读截图再点，至少约 1 分钟

1. **Read** 打开 `PNG=`（看画面，不要只扫 CLICKABLES）  
2. 按 [reference.md](reference.md) 点同意/关弹窗/填表/**注册或登录**/进首页点功能  
3. `tap` / `text` 后 `dumpshot`，再读新 PNG，多轮  
4. **从第一次有效点击到 teardown，墙钟时间 ≥ 约 60 秒**；尽量点到主流程里能点的控件（Tab、列表、我的、设置），不要点一下登录就卸包  

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>/scripts/model_ui.ps1" tap -X <x> -Y <y> -OutDir "<OutDir>"
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>/scripts/model_ui.ps1" text -Text "13800138000" -OutDir "<OutDir>"
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>/scripts/model_ui.ps1" dumpshot -OutDir "<OutDir>"
```

用户不点屏。CLICKABLES 只作辅助。测试账号见 reference。

### 3) PS：停抓 + **必须卸载**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>/scripts/model_ui.ps1" teardown -OutDir "<OutDir>"
```

必须看到 **`UNINSTALL_OK <package>`**。未卸干净禁止装下一包。  
不卸：`com.capturecli`、Magisk。

### 4) Agent：`record`

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL>/scripts/model_ui.ps1" record -OutDir ... `
  -MainDomain "<业务主域>" -ValuableDomains "..." -EvidenceIds "..." -Status mitm
```

`status`：`mitm` / `mitm_empty` / `static` / **`install_failed`**。不要用体积当 status。

---

## CSV 列

```text
apk,package,main_domain,valuable_domains,evidence_ids,all_hosts,status,notes
```

| 列 | 含义 |
|----|------|
| `main_domain` | 登录/API 业务域；装失败可填静态候选或 `none` |
| `valuable_domains` | OSS/S3/ZOS 等可调证域，带标签 |
| `evidence_ids` | `aliyun_bucket=` / `object=` / `aid=` 等 |
| `status` | `mitm` / `mitm_empty` / `static` / `install_failed` |
| 噪声 | bugly/umeng/jpush/ip.sb/unicode.org… 不进 main |

`classify_capture.py` 仅提示；以 Agent `record` 为准。

## Agent 硬规则

- 路径相对 skill；adb 用 `tools/platform-tools`；安装经 `%TEMP%` ASCII  
- **不按体积跳过**；装失败不重试该包。卡死则等 `HUNG_DETECTED`/`NEXT_APK_READY` 后做**下一个**  
- 模拟器重启后脚本会注 CA；看到 `NEXT_APK_READY` 即可 prepare 下一包  
- **每包点击测试 ≥ 约 1 分钟**，尽量触发功能；有注册/登录就填 reference 账号并点提交  
- **每包必须读 PNG 再点**；卸干净再下一包  
- `analyze_one_by_one.ps1` 仅遗留兜底  

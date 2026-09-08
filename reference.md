# 参考与踩坑

## 自带 adb

`tools/platform-tools/adb.exe` — `Resolve-Env.ps1` **优先**使用。跨设备时整包拷贝 skill 即可，不必再装 Android SDK 的 platform-tools（仍可装作备用）。

## mitmproxy（不自带）

1. Python **3.10–3.12**  
2. `pip install mitmproxy`  
3. `mitmdump --version` 能跑  
4. `capture.ps1 ca` 注入系统 CA；**模拟器重启后必须重做**

未安装时：分析脚本只做 static，并应提示用户安装。

## 状态文件

`/sdcard/capturecli-status.txt`  
成功：`mode=root-redirect ... gost=up chain=ok`

## 资产

| 文件 | 说明 |
|------|------|
| `assets/CaptureCli.apk` | `com.capturecli` + gost |
| `assets/Magisk.apk` | `io.github.huskydg.magisk` 管理端；镜像需已 root |
| `tools/platform-tools/` | Google platform-tools（Windows） |

---

## 点击测试（强制）

墙钟时间：**从第一次有效点击到 teardown ≥ 约 60 秒**。不要「点一下登录立刻卸包」。

每轮：Read PNG → 决定坐标 → `tap`/`text` → 等 2–4 秒 → `dumpshot` → 再 Read。CLICKABLES 只辅助。

尽量触发当前屏能点到的功能（协议、启动、下一步、Tab、列表项、我的、设置、借款/会议/连接）。不要点「退出应用」除非那是关掉阻塞弹窗的唯一键（如 NFC「退出」会杀进程，点完若已回桌面就结束本包）。

### 测试账号（注册 / 登录用）

`adb shell input text` **只适合 ASCII**。密码不要用 `!` `@` 等。

| 字段 | 值 |
|------|-----|
| 手机 | `13800138000` |
| 备选手机 | `19900001111` |
| 密码 | `Test123456` |
| 用户名 | `testdomain01` |
| 邮箱 | `testdomain01@gmail.com` |
| 短信验证码 | 先点「获取验证码」，等 5 秒；没有真短信则填 `123456` 再提交 |

流程（画面上有才做）：

1. 权限弹窗点 **允许**（后台运行、存储、屏幕录制「立即开始」）。**不要**为了省事点拒绝。  
2. 勾选「同意协议」（未勾时登录按钮常无效）。  
3. 点手机号框 → `text -Text 13800138000` → 点密码框 → `text -Text Test123456`。  
4. 点 **注册 / 登录 / 下一步**。失败就换备选手机再试一次。  
5. 有图形验证码：能认就填；认不出就跳过，改点其它入口（游客、跳过、首页 Tab）。  
6. 登录进首页后，把底部 Tab / 主要按钮各点一遍，直到满约 1 分钟。

辉音惠一类「启动服务」：允许后台 → 点启动 → 允许截屏 → 等接入；不要去乱点系统「无障碍」列表。  
NexP2 NFC「该设备不支持 NFC」只有「退出」：点退出后若回桌面，结束本包（`mitm_empty` 或已有流量则 `mitm`）。

---

## 安装失败 / 雷电重启（强制）

**不要用体积门禁跳过安装。** 体积只写在 `apk_size_report.csv` 供人看。

装不上的常见原因：权限冲突、`Broken pipe`、包管理器挂死、**装完或安装中 ADB 断链把雷电卡死**。一律：

1. **不要**对同一 APK 再 `prepare`（装不上的会一直失败）。  
2. 卡死由 `prepare`/`health` 检出：`HUNG_DETECTED` → 自动关开雷电并注 CA → `NEXT_APK_READY`。  
3. CSV 本行 **`status=install_failed`**（卡住时 `prepare` 会自己写；aapt/zip 损坏用 `installfail`）。  
4. **进行下一个 APK**（不要等用户点重启）。

手动：

```powershell
powershell -File "<SKILL>/scripts/model_ui.ps1" health -OutDir "<OutDir>" -Serial emulator-5554
powershell -File "<SKILL>/scripts/model_ui.ps1" rebootemu -OutDir "<OutDir>" -Serial emulator-5554
```

`install_failed` 的 `main_domain` 可以是静态抽到的业务域，或 `none`；`notes` 写 `install_failed: adb offline / emulator reboot` 等。禁止写成 `too_large` / `too_large_static`。

双 serial（`127.0.0.1:5555` 与 `emulator-5554`）易把 streamed install 打挂。优先只用一个：`emulator-5554` 或只 `connect 127.0.0.1:5555`。

---

## 常见故障

- **process is bad**：卸 CaptureCli → 重启模拟器 → 重装  
- **su 非 0**：镜像未 root / Magisk 未授权  
- **198.18 DNS**：关主机 Clash TUN  
- **MITM 全空**：pinning 或自定义加密 → `mitm_empty` 或 `static`（已装上、点满 1 分钟）  
- **adb install 中文路径失败**：脚本已拷 `%TEMP%`  
- **uiautomator null root**：安全界面 / 白屏；再 `shot` 一次，仍无 UI 则靠静态 + 已有流量  

## 速查

```powershell
$S = "<SKILL>/scripts"
& "<SKILL>/tools/platform-tools/adb.exe" version
mitmdump --version
powershell -File "$S\setup_first_run.ps1"
powershell -File "$S\capture.ps1" ca
powershell -File "$S\capture.ps1" mitm
powershell -File "$S\model_ui.ps1" recover -OutDir "<OutDir>"
```

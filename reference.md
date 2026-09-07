# 参考与踩坑

## 自带 adb

`tools/platform-tools/adb.exe` — `Resolve-Env.ps1` **优先**使用。跨设备时整包拷贝 skill 即可，不必再装 Android SDK 的 platform-tools（仍可装作备用）。

## mitmproxy（不自带）

见 `SKILL.md`「安装 mitmproxy」。要点：

1. Python **3.10–3.12**（避免过新无轮子）  
2. `pip install mitmproxy`  
3. `mitmdump --version` 能跑  
4. `capture.ps1 ca` 注入系统 CA；重启模拟器后重做  

未安装时：`Find-MitmDump` 返回空 → 分析脚本只做 static 域名，并应提示用户安装。

## 状态文件

`/sdcard/capturecli-status.txt`  
成功：`mode=root-redirect ... gost=up chain=ok`

## 资产

| 文件 | 说明 |
|------|------|
| `assets/CaptureCli.apk` | `com.capturecli` + gost |
| `assets/Magisk.apk` | `io.github.huskydg.magisk` 管理端；镜像需已 root |
| `tools/platform-tools/` | Google platform-tools（Windows） |

## 常见故障

- **process is bad**：卸 CaptureCli → 重启模拟器 → 重装  
- **su 非 0**：镜像未 root / Magisk 未授权  
- **198.18 DNS**：关主机 Clash TUN，或依赖 CaptureCli DNS 链  
- **MITM 全空**： pinning 或未装 mitm → static 兜底  
- **adb install 中文路径失败**：脚本已拷 `%TEMP%`

## 速查

```powershell
$S = "<SKILL>/scripts"
# 确认自带 adb
& "<SKILL>/tools/platform-tools/adb.exe" version
# mitm（需已 pip install）
mitmdump --version
powershell -File "$S\setup_first_run.ps1"
powershell -File "$S\capture.ps1" ca
powershell -File "$S\capture.ps1" mitm
```

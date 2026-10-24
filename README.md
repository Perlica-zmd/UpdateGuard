# 更新守卫 · Update Guard

Windows 更新 与 Microsoft Store 应用自动更新的管理工具。  
两种形态：**纯 PowerShell 脚本（推荐）** + 带界面的单文件 exe（.NET Framework 4.8，零依赖）。

![界面](docs/gui.png)

---

## 下载

**推荐用脚本版：[`tools/Disable-WindowsUpdate.ps1`](tools/Disable-WindowsUpdate.ps1)**（约 38 KB）

1. 打开上面的链接，点右上角 **Raw** 保存
2. 右键文件 → 属性 → 勾选「解除锁定」（或运行 `Unblock-File .\Disable-WindowsUpdate.ps1`）
3. 右键 → **使用 PowerShell 运行**，UAC 点「是」

推荐它的理由：

- **纯文本**，几十 KB，下载前可以先通读代码再决定要不要跑
- 不用编译、不用装运行时、不用签名证书
- **不会被 SmartScreen 拦**（未签名的 exe 会被拦）
- 想改就改：换策略、加任务、塞进部署脚本都行

exe 版放在 **Releases** 页面（仓库里不带二进制），适合不想碰命令行的人。自己编译也就一条命令，见[构建](#构建)。

---

## 两种形态

| | 脚本版 ✅ 推荐 | 界面版 |
|---|---|---|
| 文件 | `tools/Disable-WindowsUpdate.ps1` | `dist/UpdateGuard.exe`（Releases） |
| 体积 | 38 KB 纯文本 | ~125 KB 单文件 |
| 依赖 | Windows PowerShell 5.1 | .NET Framework 4.8（Win10/11 自带） |
| 提权 | 启动时自己请求 UAC | 点按钮时自己请求 UAC |
| 安全预览 | ✅ 能读完所有代码 | ❌ 二进制 |
| SmartScreen | ✅ 不拦 | ⚠️ 未签名会被拦 |
| 适合 | **默认推荐**、想审代码 / 改代码 / 自动化 | 不想碰命令行 |

两者共用同一个数据目录，可以互相接手。

---

## 为什么需要它

把 `wuauserv` 等服务设成"禁用"是最直觉的做法，但 Windows 会在几小时到几天内把它们改回默认值
（`WaaSMedicSvc` 就是专门干这个的）。本机日志里能直接看到这种拉锯：

```
09-30 17:47:35  Windows 更新 服务的启动类型从 已禁用 更改为 按需启动
10-08 22:11:03  Windows 更新 服务的启动类型从 已禁用 更改为 按需启动
10-14 22:00:58  WaaSMedicSvc 服务的启动类型从 已禁用 更改为 按需启动
```

所以本工具的重点**不是**"把服务锁死"，而是写一层 Windows 支持的**企业策略**（更新源指向不存在的内网
WSUS + 禁止连接微软更新服务器）。服务栈会尊重这个配置，不会去"修复"它 —— 实测策略写下去之后
一个月没被动过，期间没有安装任何系统更新。

服务启动类型和计划任务仍然会一起处理，但它们只是辅助层。

---

## 功能

- **禁用 / 恢复 Windows 更新**（策略 + 5 个服务 + 4 个目录下全部计划任务）
- **关闭 Microsoft Store 应用自动更新**（`WindowsStore\AutoDownload = 2`）
- **状态一览**：服务启动类型直接问 SCM（`sc qc`），不受注册表键权限影响
- **进度条**，逐行过程默认折叠；出错才自动展开详细日志（`-Detail` 可强制展开）
- **可完整恢复**：自动备份原始任务 XML 与服务启动类型基线
- **ACL 修复**：早期版本给服务键加过 Deny ACE，会把键权限改坏；内置"抢所有权 + 还原原始 DACL"来收拾

---

## 它到底改了什么

| 位置 | 内容 |
|---|---|
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | `WUServer` / `WUStatusServer` = `http://127.0.0.1:8530`（不存在的地址）、`DoNotConnectToWindowsUpdateInternetLocations` = 1 |
| `...\WindowsUpdate\AU` | `NoAutoUpdate` = 1、`UseWUServer` = 1 |
| `HKLM\SOFTWARE\Policies\Microsoft\WindowsStore` | `AutoDownload` = 2（关闭 Store 应用自动更新） |
| 服务 | `wuauserv` `usosvc` `dosvc` `WaaSMedicSvc` `bits` → 禁用并停止 |
| 计划任务 | `\Microsoft\Windows\{UpdateOrchestrator, WaaSMedic, WindowsUpdate, InstallService}\*` → 禁用 |

受保护的任务无法通过 API 禁用，改为直接改写任务 XML 的 `Settings/Enabled`，
再临时给 `Schedule` 服务补上 `SERVICE_STOP` 权限重载（用完立刻还原 SDDL）。

恢复时的顺序相反：解锁 → 按基线还原服务 → 删除策略 → 用备份还原任务 → `gpupdate /force`。

---

## 为什么不用"锁注册表 ACL"

早期版本给服务键加过 `Deny SetValue`，思路是"让任何进程都改不回来"。**这条路走不通**：

- Deny 只挡 `SetValue`，不挡 `WRITE_DAC`。而 SYSTEM / TrustedInstaller 对这些键本来就有
  `KEY_ALL_ACCESS`，先改 DACL 再写值即可绕过。
- 实测三次被绕过（9/30、10/8、10/14），最长撑了 7 天。
- 副作用：`SetAccessControl` 会把继承来的 ACE 固化成显式 ACE，导致这几个键**连管理员都打不开**，
  最后连本工具自己都写不进 `Start`。

所以新版本把锁定整个删掉了，只保留"修复历史遗留"的能力。

---

## 构建

只需要 Windows 自带的编译器，**不需要装 Visual Studio 或 .NET SDK**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

产物在 `dist\UpdateGuard.exe`。

几个踩过的坑，构建脚本已经处理：

- 自带 `csc.exe` 是 legacy 编译器，**只支持 C# 5**（没有字符串插值 / `?.` / `nameof` / 元组）
- 源码是 UTF-8，必须带 `/codepage:65001`，否则中文字面量会变成乱码
- `build\app.ico` 是构建时用 GDI+ 画出来的，不在仓库里

### 签名（可选）

```powershell
.\sign.ps1          # 用自签名证书签 dist\UpdateGuard.exe，并导出 dist\UpdateGuard.cer
```

自签名只能去掉 UAC 里的"未知发布者"（对方需先跑 `tools\trust-cert.bat` 把证书装进本机受信任根），
**去不掉 SmartScreen**。想彻底没有警告只能买 OV 证书或用 Azure Artifact Signing。

---

## 使用

### 脚本版（推荐）

```powershell
# 交互菜单（最简单：右键 -> 使用 PowerShell 运行）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Disable-WindowsUpdate.ps1

# 非交互
... -File .\tools\Disable-WindowsUpdate.ps1 -Auto disable
... -File .\tools\Disable-WindowsUpdate.ps1 -Auto restore
... -File .\tools\Disable-WindowsUpdate.ps1 -Auto repair    # 修复旧版 ACL 遗留
... -File .\tools\Disable-WindowsUpdate.ps1 -Auto status    # 不需要提权

# 想看每一步的逐行输出
... -File .\tools\Disable-WindowsUpdate.ps1 -Auto disable -Detail
```

> 脚本文件必须保持 **UTF-8 with BOM**。PowerShell 5.1 会把无 BOM 的文件按 ANSI 读，中文直接变乱码报语法错。

同样是进度条，逐行过程默认折叠：

![脚本进度条](docs/ps_progress_bar.png)

### 界面版

双击 `UpdateGuard.exe` → 点「禁用更新」→ **再点一次确认**（5 秒内，防误触）→ UAC 点是。

按钮行为：第一次点击只是确认，第二次才执行。

---

## 目录结构

```
.
├─ src/                      C# 源码
│  ├─ Program.cs             入口 / 崩溃日志 / --selftest
│  ├─ MainForm.cs            界面与交互
│  ├─ Theme.cs               Win11 Fluent 主题与按钮
│  ├─ WuCore.cs              禁用/恢复/状态 全部逻辑
│  ├─ AclFix.cs              注册表键 ACL 修复（抢所有权 + 还原 DACL）
│  ├─ Native.cs              DWM 圆角 / 窗口拖动
│  └─ AssemblyInfo.cs
├─ build/app.manifest        asInvoker + DPI 感知
├─ tools/
│  ├─ Disable-WindowsUpdate.ps1   PowerShell 版
│  ├─ trust-cert.ps1              把自签名证书装进本机受信任根
│  └─ trust-cert.bat              ↑ 的批处理入口
├─ docs/                     截图
├─ build.ps1                 构建（生成图标 + 调 csc）
├─ sign.ps1                  签名 + 导出 .cer
├─ CHANGELOG.md
└─ LICENSE
```

## 数据目录

`C:\ProgramData\UpdateGuard\`

| 文件 | 说明 |
|---|---|
| `log.txt` | 运行日志（GUI 与脚本共用） |
| `services.txt` | 服务启动类型基线，恢复时用 |
| `tasks\*.xml` | 受保护任务的原始 XML 备份 |
| `acl\*.sddl` | 服务键原始 DACL 备份（仅旧版遗留，修好后自动删除） |
| `error.log` | 崩溃日志 |

卸载 = 删掉 exe 和这个目录。

---

## 已知限制

- **未签名时**：可能被 SmartScreen 拦（"更多信息 → 仍要运行"），个别杀软可能误报
  —— 它确实在改服务启动类型和计划任务。
- **Windows 仍会试图自我修复**：服务启动类型和计划任务可能被改回，策略不受影响。
  如果发现更新又回来了，先看 `log.txt`，再跑一次即可。
- **策略挡不住手动操作**：用户主动去"设置 → Windows 更新 → 检查更新"仍可能触发，
  只是更新源指向不存在的服务器。
- 本工具不代替打补丁。长期禁用请自行评估安全风险。

## License

[MIT](LICENSE)

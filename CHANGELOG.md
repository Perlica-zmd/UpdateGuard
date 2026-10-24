# Changelog

## 2.0

PowerShell 版重写，并把"禁用"的思路从"锁死配置"改成"写策略"。

- 策略改为企业 WSUS 指向方案：`WUServer` / `WUStatusServer` 指向不存在的地址，
  并置 `DoNotConnectToWindowsUpdateInternetLocations=1`、`AU\NoAutoUpdate=1`、`AU\UseWUServer=1`。
  服务栈会尊重这个配置，不会像改服务启动类型那样出手"修复"。
- 新增关闭 Microsoft Store 应用自动更新：`HKLM\SOFTWARE\Policies\Microsoft\WindowsStore\AutoDownload=2`
  （值取自本机 `WindowsStore.admx`：启用=2，禁用=3）。`NoAutoUpdate` 管不到 Store 应用，那是独立通道。
- **移除服务注册表键的 ACL 锁定**。`Deny SetValue` 挡不住持有 `WRITE_DAC` 的 SYSTEM / TrustedInstaller，
  实测三次被绕过（9/30、10/8、10/14），还把键的 DACL 改坏，最后连本工具自己都写不进 `Start`。
- 服务启动类型的读取改为直接问 SCM（`sc qc`），注册表读不到时自动回退。
  之前读不到会返回 `-1`，被误判成"被改回"，60 秒里刷了 20 条假警告。
- 新增 ACL 修复：抢所有权（`SeTakeOwnershipPrivilege`）+ 按备份 SDDL 还原 DACL，收拾旧版遗留。
- 进度条：过程默认折叠，出错才展开详细日志；`-Detail` 可强制展开。
- 脚本文件改为自绘单行进度条（`Write-Progress` 在部分宿主里不渲染）。

## 1.3

- 修 `Set-TaskXmlEnabled` 调用处多写的 `-not`（参数被取反，"禁用"时反而启用了受保护任务）。
- XML 改写改用 DOM，只动 `Settings/Enabled`，不再用 `-replace` 误伤 `<Triggers>` 里的开关。
- 计划任务清单补齐 `InstallService\*` 与整个 `WindowsUpdate\*`。
- 改完 XML 后重载任务计划程序（`Schedule` 的 DACL 不给管理员 `SERVICE_STOP`，
  临时补 `WP` 重载后立刻还原 SDDL）。
- 恢复时优先用 `backup\tasks` 里的原始 XML。
- 服务启动类型基线：`Start=4` 视为"未知"，避免把"禁用"当成原始配置。
- 服务默认值修正为 `wuauserv/WaaSMedicSvc=手动`、`bits/usosvc/dosvc=自动(延迟)`。

## 1.2

- 修正 XML 改写参数取反的严重 bug。
- 补上 `InstallService` / `WindowsUpdate` 的任务覆盖。
- `Get-ScheduledTask` 返回空集合时不再当成"成功 0 个"。

## 1.1

- 首个可用版本：停服务 + 禁服务 + 组策略 + 禁计划任务。

## 1.0

- 初始版本。

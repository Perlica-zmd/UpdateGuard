#requires -Version 5.1
<#
  更新守卫 · Update Guard — PowerShell 版
  禁用 / 恢复 Windows 更新 + 关闭 Microsoft Store 应用自动更新
  作者: Perlica   License: MIT

  思路: 真正长期有效的是"策略"(更新源指向不存在的内网 WSUS + 禁止连微软更新服务器),
        服务启动类型和计划任务只是辅助层 —— Windows 会主动把它们改回去。

  用法:
    A. 右键 -> 使用 PowerShell 运行 (会自己请求管理员)
    B. powershell -NoProfile -ExecutionPolicy Bypass -File "本文件路径"
    C. 非交互: -Auto disable | restore | status | repair  [-Detail]

  数据目录 (与 exe 版共用): C:\ProgramData\UpdateGuard\
    log.txt / services.txt / tasks\*.xml / acl\*.sddl

  注意: 本文件必须保持 UTF-8 with BOM, 否则 PowerShell 5.1 会按 ANSI 读, 中文变乱码。
#>

[CmdletBinding()]
param(
    [ValidateSet('','disable','restore','status','repair')]
    [string]$Auto = '',
    # 默认把逐行过程折叠成进度条; 加 -Detail 才打印每一步
    [switch]$Detail
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

# ---------- 自提权 ----------
$isElev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
# 只读的状态查询不需要提权, 方便直接看
$needElev = -not ($Auto -eq 'status')
if ((-not $isElev) -and $needElev) {
    Write-Host '需要管理员权限, 正在请求(UAC 弹窗请点"是")...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ("`"$PSCommandPath`""))
    if ($Auto) { $argList += @('-Auto', $Auto) }
    if ($Detail) { $argList += '-Detail' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}

# ---------- 常量 ----------
$script:SvcCore   = @('wuauserv', 'usosvc', 'dosvc', 'WaaSMedicSvc', 'bits')
$script:StopOrder = @('usosvc', 'WaaSMedicSvc', 'wuauserv', 'dosvc', 'bits')
$script:ProcNames = @('MoUsoCoreWorker', 'TiWorker', 'wuauclt', 'usoclient')

$script:TaskFolders = @(
    'C:\Windows\System32\Tasks\Microsoft\Windows\UpdateOrchestrator',
    'C:\Windows\System32\Tasks\Microsoft\Windows\WaaSMedic',
    'C:\Windows\System32\Tasks\Microsoft\Windows\WindowsUpdate',
    'C:\Windows\System32\Tasks\Microsoft\Windows\InstallService'
)
$script:TasksRoot = 'C:\Windows\System32\Tasks'
$script:TaskNs    = 'http://schemas.microsoft.com/windows/2004/02/mit/task'

$script:PolicyWU    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:PolicyAU    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:PolicyStore = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
$script:FakeWsus    = 'http://127.0.0.1:8530'

$script:DataDir     = Join-Path $env:ProgramData 'UpdateGuard'
$script:LogFile     = Join-Path $script:DataDir 'log.txt'
$script:Baseline    = Join-Path $script:DataDir 'services.txt'
$script:TaskBackup  = Join-Path $script:DataDir 'tasks'
$script:AclBackup   = Join-Path $script:DataDir 'acl'

$script:SddlNoStop = 'CCLCSWRPDTLOCRRCWDWO;;;BA'
$script:SddlWithStop = 'CCLCSWRPWPDTLOCRRCWDWO;;;BA'

function Initialize-Dirs {
    foreach ($d in @($script:DataDir, $script:TaskBackup, $script:AclBackup)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

# ---------- 日志 ----------
# 过程默认折叠: 只把警告/错误打到控制台, 其余进日志文件; 进度用进度条呈现
function Write-Log([string]$msg, [string]$level = 'Info') {
    $tag = switch ($level) { 'Ok' { '[Ok  ]' } 'Warn' { '[Warn]' } 'Err' { '[Err ]' } default { '[Info]' } }
    $line = "{0}  {1} {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $tag, $msg
    $color = switch ($level) { 'Ok' { 'Green' } 'Warn' { 'Yellow' } 'Err' { 'Red' } default { 'Gray' } }
    if ($Detail -or $level -eq 'Warn' -or $level -eq 'Err') {
        Clear-Bar
        Write-Host $line -ForegroundColor $color
    }
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}

# ---------- 进度条 ----------
# 不用 Write-Progress: 它在某些宿主(ISE/重定向/部分终端)里根本不渲染。
# 这里自己画一条单行进度条, 用 \r 原地刷新, 任何控制台都看得见。
$script:BarWidth = 0

function Update-Bar([int]$pct, [string]$stage) {
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $w = 34
    $filled = [int][math]::Floor($w * $pct / 100.0)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $w) { $filled = $w }
    $bar = ('█' * $filled) + (' ' * ($w - $filled))
    $line = "  [{0}] {1,3}%  {2}" -f $bar, $pct, $stage
    if ($line.Length -lt $script:BarWidth) { $line = $line.PadRight($script:BarWidth) }
    $script:BarWidth = $line.Length
    try {
        [Console]::Write("`r" + $line)
    } catch {
        try { Write-Progress -Activity '更新守卫' -Status $stage -PercentComplete $pct } catch { }
    }
}

# 打日志前先把进度条那行擦掉, 免得两行糊在一起
function Clear-Bar {
    if ($script:BarWidth -gt 0) {
        try { [Console]::Write("`r" + (' ' * $script:BarWidth) + "`r") } catch { }
        $script:BarWidth = 0
    }
}

function Complete-Bar {
    try { [Console]::WriteLine() } catch { }
    $script:BarWidth = 0
    try { Write-Progress -Activity '更新守卫' -Completed } catch { }
}

# =====================================================================
#  服务: 全部走 SCM, 不碰注册表
# =====================================================================

# 返回 SCM 里的启动类型: 2=自动 3=手动 4=禁用 -1=读不到
function Get-SvcStartType([string]$name) {
    $out = & sc.exe qc $name 2>&1
    if ($LASTEXITCODE -ne 0) { return -1 }
    foreach ($line in $out) {
        if ($line -match 'START_TYPE\s*:\s*(\d)') { return [int]$Matches[1] }
    }
    return -1
}

function Get-SvcStartText([int]$st) {
    switch ($st) {
        2 { '自动' }
        3 { '手动' }
        4 { '已禁用' }
        default { '未知' }
    }
}

function Set-SvcStartMode([string]$name, [string]$mode) {
    # $mode: disabled / demand / auto / delayed-auto
    $null = & sc.exe config $name start= $mode 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Stop-OneService([string]$name, [int]$timeoutSec = 20) {
    $null = & sc.exe stop $name 2>&1
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $q = & sc.exe query $name 2>&1
        if ($LASTEXITCODE -ne 0) { return $true }          # 服务不存在
        if (($q -join ' ') -match 'STOPPED') { return $true }
    }
    return $false
}

function Stop-AllServices([int]$rounds = 3) {
    for ($r = 1; $r -le $rounds; $r++) {
        $running = @()
        foreach ($n in $script:StopOrder) {
            $q = & sc.exe query $n 2>&1
            if ($LASTEXITCODE -eq 0 -and -not (($q -join ' ') -match 'STOPPED')) { $running += $n }
        }
        if ($running.Count -eq 0) { Write-Log '所有更新相关服务均已停止' 'Ok'; return }
        Write-Log ("第 {0} 轮停止: {1}" -f $r, ($running -join ', '))
        foreach ($n in $running) {
            if (Stop-OneService $n) { Write-Log ("  {0} : 已停止" -f $n) 'Ok' }
            else { Write-Log ("  {0} : 未能停止(可能正忙)" -f $n) 'Warn' }
        }
        if ($r -eq 1) { Start-Sleep -Seconds 1; Stop-UpdateProcesses }
        Start-Sleep -Seconds 2
    }
}

function Stop-UpdateProcesses {
    foreach ($p in $script:ProcNames) {
        Get-Process -Name $p -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.Kill() } catch { }
        }
    }
    Write-Log '已结束残留更新进程(如有)' 'Ok'
}

# 复核: SCM 里不是"禁用"的服务(不会误报, 因为不读注册表)
function Get-NonDisabledServices {
    $bad = @()
    foreach ($n in $script:SvcCore) {
        $st = Get-SvcStartType $n
        if ($st -ne 4) { $bad += ("{0}({1})" -f $n, (Get-SvcStartText $st)) }
    }
    return $bad
}

# =====================================================================
#  策略
# =====================================================================
function Set-WuPolicy([bool]$on) {
    try {
        if ($on) {
            if (-not (Test-Path $script:PolicyWU)) { New-Item -Path $script:PolicyWU -Force | Out-Null }
            New-ItemProperty -Path $script:PolicyWU -Name 'WUServer' -Value $script:FakeWsus -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $script:PolicyWU -Name 'WUStatusServer' -Value $script:FakeWsus -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $script:PolicyWU -Name 'DoNotConnectToWindowsUpdateInternetLocations' -Value 1 -PropertyType DWord -Force | Out-Null
            if (-not (Test-Path $script:PolicyAU)) { New-Item -Path $script:PolicyAU -Force | Out-Null }
            New-ItemProperty -Path $script:PolicyAU -Name 'NoAutoUpdate' -Value 1 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $script:PolicyAU -Name 'UseWUServer'  -Value 1 -PropertyType DWord -Force | Out-Null
            Write-Log ("组策略: 更新源 -> {0}, 禁止连微软更新服务器, NoAutoUpdate=1" -f $script:FakeWsus) 'Ok'
        } else {
            Remove-Item -Path $script:PolicyWU -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log '组策略: 已删除 WindowsUpdate 全部策略(含 WSUS 指向)' 'Ok'
        }
    } catch {
        Write-Log ('组策略写入失败: ' + $_.Exception.Message) 'Err'
    }
}

function Set-StorePolicy([bool]$on) {
    try {
        if ($on) {
            if (-not (Test-Path $script:PolicyStore)) { New-Item -Path $script:PolicyStore -Force | Out-Null }
            New-ItemProperty -Path $script:PolicyStore -Name 'AutoDownload' -Value 2 -PropertyType DWord -Force | Out-Null
            Write-Log '组策略: 已关闭 Store 应用自动更新 (WindowsStore\AutoDownload=2)' 'Ok'
        } else {
            try {
                $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                        'SOFTWARE\Policies\Microsoft\WindowsStore', $true)
                if ($k) {
                    $k.DeleteValue('AutoDownload', $false)
                    $empty = ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0)
                    $k.Close()
                    # 只在键已空时删除, 避免误删别人写的 RemoveWindowsStore 等策略
                    if ($empty) {
                        [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKey(
                            'SOFTWARE\Policies\Microsoft\WindowsStore', $false)
                    }
                }
            } catch { }
            Write-Log '组策略: 已恢复 Store 应用自动更新设置' 'Ok'
        }
    } catch {
        Write-Log ('Store 策略写入失败: ' + $_.Exception.Message) 'Err'
    }
}

# =====================================================================
#  计划任务
# =====================================================================
function Get-UpdateTasks {
    $list = @()
    foreach ($folder in $script:TaskFolders) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $files = @()
        try { $files = Get-ChildItem -LiteralPath $folder -File -Recurse -Force -ErrorAction SilentlyContinue } catch { continue }
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($script:TasksRoot.Length)
            $i = $rel.LastIndexOf('\')
            if ($i -lt 0) { continue }
            $list += [pscustomobject]@{
                FilePath = $f.FullName
                TaskPath = $rel.Substring(0, $i + 1)
                TaskName = $rel.Substring($i + 1)
                Enabled  = (Get-TaskEnabledState $rel.Substring(0, $i + 1) $rel.Substring($i + 1) $f.FullName)
            }
        }
    }
    return $list
}

# 任务是否启用: 先问任务计划程序(权威), 问不到再退回读 XML 文件。
# 不能只看文件: 任务被 API 禁用后, 若 XML 文件被写保护, 文件内容会一直是过期的"启用"。
function Get-TaskEnabledState([string]$taskPath, [string]$taskName, [string]$file) {
    try {
        $t = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
        if ($null -ne $t) {
            if ($t.State -eq 'Disabled') { return $false }
            if ($t.State -eq 'Ready' -or $t.State -eq 'Running') { return $true }
        }
    } catch { }
    return (Read-TaskEnabled $file)
}

function Read-TaskEnabled([string]$file) {
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.PreserveWhitespace = $true
        $doc.Load($file)
        $nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
        $nsm.AddNamespace('t', $script:TaskNs)
        $settings = $doc.SelectSingleNode('/t:Task/t:Settings', $nsm)
        if (-not $settings) { return $true }
        $en = $settings.SelectSingleNode('t:Enabled', $nsm)
        if (-not $en) { return $true }
        return ($en.InnerText.Trim() -ne 'false')
    } catch { return $true }
}

function Get-TaskBackupName([string]$taskPath, [string]$taskName) {
    return ($taskPath.Trim('\') -replace '\\', '_') + '_' + $taskName + '.xml'
}

function Grant-AdminOnFile([string]$file) {
    $null = & takeown.exe /F $file /A 2>&1
    $null = & icacls.exe $file /grant '*S-1-5-32-544:(F)' 2>&1
}

# 只改 /Task/Settings/Enabled, 不碰 <Triggers> 里的 <Enabled>
function Set-TaskXmlEnabled([string]$taskPath, [string]$taskName, [bool]$enabled) {
    $file = "$($script:TasksRoot)$taskPath$taskName"
    if (-not (Test-Path -LiteralPath $file)) { return $false }

    $bak = Join-Path $script:TaskBackup (Get-TaskBackupName $taskPath $taskName)
    if (-not (Test-Path -LiteralPath $bak)) {
        try { Copy-Item -LiteralPath $file -Destination $bak -Force -ErrorAction Stop }
        catch { Write-Log ('  备份失败(仍继续改写): ' + $taskName) 'Warn' }
    }

    Grant-AdminOnFile $file
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.PreserveWhitespace = $true
        $doc.Load($file)
        $nsm = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
        $nsm.AddNamespace('t', $script:TaskNs)
        $settings = $doc.SelectSingleNode('/t:Task/t:Settings', $nsm)
        if (-not $settings) { return $false }

        $en = $settings.SelectSingleNode('t:Enabled', $nsm)
        if (-not $en) {
            $en = $doc.CreateElement('Enabled', $script:TaskNs)
            $null = $settings.AppendChild($en)
        }
        $want = if ($enabled) { 'true' } else { 'false' }
        if ($en.InnerText.Trim() -ne $want) {
            $en.InnerText = $want
            $doc.Save($file)
        }
        return $true
    } catch {
        Write-Log ('  XML 改写失败 ' + $taskName + ': ' + $_.Exception.Message) 'Warn'
        return $false
    }
}

function Restore-TaskFromBackup([string]$taskPath, [string]$taskName) {
    $bak = Join-Path $script:TaskBackup (Get-TaskBackupName $taskPath $taskName)
    if (-not (Test-Path -LiteralPath $bak)) { return $false }
    $dst = "$($script:TasksRoot)$taskPath$taskName"
    if (-not (Test-Path -LiteralPath $dst)) { return $false }
    try {
        Grant-AdminOnFile $dst
        Copy-Item -LiteralPath $bak -Destination $dst -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

# 任务计划程序的重启: 本机 Schedule 的 DACL 只给 SYSTEM SERVICE_STOP,
# 管理员没有 WP, 但管理员有 WD(WRITE_DAC): 临时补上 WP, 重载后立刻还原。
function Restart-TaskScheduler {
    try {
        Restart-Service -Name Schedule -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Log '已重载任务计划程序, 任务改动立即生效' 'Ok'
        return $true
    } catch {
        Write-Log ('直接重启任务计划程序失败: ' + $_.Exception.Message) 'Warn'
    }

    $orig = ((& sc.exe sdshow Schedule 2>&1) -join '').Trim()
    if ($orig -notmatch [regex]::Escape($script:SddlNoStop)) {
        Write-Log 'Schedule 的 SDDL 与预期不一致, 为安全起见不自动改动' 'Warn'
        return $false
    }
    $patched = $orig -replace [regex]::Escape($script:SddlNoStop), $script:SddlWithStop
    $null = & sc.exe sdset Schedule $patched 2>&1
    $ok = $false
    try {
        Restart-Service -Name Schedule -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        $ok = $true
    } catch {
        Write-Log ('临时授权后仍未能重启: ' + $_.Exception.Message) 'Warn'
    } finally {
        $null = & sc.exe sdset Schedule $orig 2>&1
        Write-Log '已还原 Schedule 服务的原始 SDDL' 'Ok'
    }
    if ($ok) { Write-Log '已在临时授权下重载任务计划程序, 任务改动立即生效' 'Ok' }
    return $ok
}

# =====================================================================
#  基线
# =====================================================================
function Save-Baseline {
    Initialize-Dirs
    if (Test-Path -LiteralPath $script:Baseline) { return }
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in $script:SvcCore) {
        $st = Get-SvcStartType $n
        if ($st -eq 4) { $st = -1 }        # 本来就禁用 -> 视为未知, 不当成原始配置
        $dl = -1
        try {
            $v = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$n" -Name DelayedAutoStart -ErrorAction SilentlyContinue).DelayedAutoStart
            if ($null -ne $v) { $dl = [int]$v }
        } catch { }
        $null = $sb.AppendLine("$n=$st,$dl")
    }
    try {
        Set-Content -LiteralPath $script:Baseline -Value $sb.ToString() -Encoding UTF8
        Write-Log '已记录服务启动类型基线' 'Ok'
    } catch { Write-Log ('基线写入失败: ' + $_.Exception.Message) 'Warn' }
}

function Get-BaselineMap {
    # 系统默认值兜底(依据实机 7040 日志里 Windows 自己恢复到的值)
    $defaults = @{
        wuauserv = @(3, 0); WaaSMedicSvc = @(3, 0)
        usosvc = @(2, 1);   dosvc = @(2, 1); bits = @(2, 1)
    }
    $map = @{}
    if (Test-Path -LiteralPath $script:Baseline) {
        try {
            foreach ($line in Get-Content -LiteralPath $script:Baseline) {
                $eq = $line.IndexOf('=')
                if ($eq -le 0) { continue }
                $n = $line.Substring(0, $eq).Trim()
                $parts = $line.Substring($eq + 1).Split(',')
                $st = 0
                if (-not [int]::TryParse($parts[0].Trim(), [ref]$st)) { continue }
                if ($st -eq 4 -or $st -le 0) { continue }    # 未知 -> 用默认值
                $dl = -1
                if ($parts.Length -gt 1) { [void][int]::TryParse($parts[1].Trim(), [ref]$dl) }
                $map[$n] = @($st, $dl)
            }
        } catch { Write-Log '基线读取失败, 使用系统默认值' 'Warn' }
    }
    foreach ($n in $script:SvcCore) {
        if (-not $map.ContainsKey($n)) { $map[$n] = $defaults[$n] }
    }
    return $map
}

# =====================================================================
#  服务键 ACL 修复(收拾旧版 ACL 锁定留下的烂摊子)
# =====================================================================
if (-not ('LiquidWU.AclFixer' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace LiquidWU
{
    public static class AclFixer
    {
        const int SE_REGISTRY_KEY = 4;
        const int OWNER_SECURITY_INFORMATION = 1;
        const int DACL_SECURITY_INFORMATION = 4;
        const int WRITE_OWNER = 0x00080000;
        const int WRITE_DAC = 0x00040000;

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern int RegOpenKeyEx(IntPtr hKey, string lpSubKey, int ulOptions, int samDesired, out IntPtr phkResult);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern int RegCloseKey(IntPtr hKey);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern int SetSecurityInfo(IntPtr handle, int ObjectType, int SecurityInfo,
            IntPtr psidOwner, IntPtr psidGroup, IntPtr pDacl, IntPtr pSacl);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
            string StringSecurityDescriptor, int StringSDRevision,
            out IntPtr SecurityDescriptor, IntPtr SecurityDescriptorSize);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern IntPtr LocalFree(IntPtr hMem);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool GetSecurityDescriptorDacl(IntPtr pSecurityDescriptor,
            out bool lpbDaclPresent, out IntPtr pDacl, out bool lpbDaclDefaulted);

        [StructLayout(LayoutKind.Sequential)]
        struct LUID { public uint LowPart; public int HighPart; }

        [StructLayout(LayoutKind.Sequential)]
        struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

        [StructLayout(LayoutKind.Sequential)]
        struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privilege; }

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges,
            ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr hObject);

        static readonly IntPtr HKEY_LOCAL_MACHINE = new IntPtr(unchecked((int)0x80000002));

        static void EnablePrivilege(string name)
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out token)) return;
            try
            {
                LUID luid;
                if (!LookupPrivilegeValue(null, name, out luid)) return;
                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.PrivilegeCount = 1;
                tp.Privilege.Luid = luid;
                tp.Privilege.Attributes = 0x00000002;
                AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            }
            finally { CloseHandle(token); }
        }

        // 把键的属主改成 BUILTIN\Administrators (S-1-5-32-544)
        public static bool TakeOwnership(string subKey, out string error)
        {
            error = "";
            try
            {
                EnablePrivilege("SeTakeOwnershipPrivilege");
                EnablePrivilege("SeRestorePrivilege");

                IntPtr h;
                int rc = RegOpenKeyEx(HKEY_LOCAL_MACHINE, subKey, 0, WRITE_OWNER, out h);
                if (rc != 0) { error = "RegOpenKeyEx(WRITE_OWNER) rc=" + rc; return false; }
                try
                {
                    byte[] sid = new byte[] { 1, 2, 0, 0, 0, 0, 0, 5, 32, 0, 0, 0, 32, 2, 0, 0 };
                    IntPtr pSid = Marshal.AllocHGlobal(sid.Length);
                    try
                    {
                        Marshal.Copy(sid, 0, pSid, sid.Length);
                        rc = SetSecurityInfo(h, SE_REGISTRY_KEY, OWNER_SECURITY_INFORMATION,
                                             pSid, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                        if (rc != 0) { error = "SetSecurityInfo(owner) rc=" + rc; return false; }
                    }
                    finally { Marshal.FreeHGlobal(pSid); }
                }
                finally { RegCloseKey(h); }
                return true;
            }
            catch (Exception ex) { error = ex.Message; return false; }
        }

        // 按 SDDL 还原 DACL
        public static bool SetDaclFromSddl(string subKey, string sddl, out string error)
        {
            error = "";
            try
            {
                EnablePrivilege("SeRestorePrivilege");

                IntPtr sd;
                if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, out sd, IntPtr.Zero))
                { error = "SDDL 解析失败 err=" + Marshal.GetLastWin32Error(); return false; }
                try
                {
                    bool present, defaulted;
                    IntPtr dacl;
                    if (!GetSecurityDescriptorDacl(sd, out present, out dacl, out defaulted) || !present)
                    { error = "SDDL 中没有 DACL"; return false; }

                    IntPtr h;
                    int rc = RegOpenKeyEx(HKEY_LOCAL_MACHINE, subKey, 0, WRITE_DAC, out h);
                    if (rc != 0) { error = "RegOpenKeyEx(WRITE_DAC) rc=" + rc; return false; }
                    try
                    {
                        rc = SetSecurityInfo(h, SE_REGISTRY_KEY, DACL_SECURITY_INFORMATION,
                                             IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
                        if (rc != 0) { error = "SetSecurityInfo(dacl) rc=" + rc; return false; }
                    }
                    finally { RegCloseKey(h); }
                }
                finally { LocalFree(sd); }
                return true;
            }
            catch (Exception ex) { error = ex.Message; return false; }
        }
    }
}
'@ -ErrorAction Stop
}

function Repair-ServiceKeyAcl([string]$name) {
    $bak = Join-Path $script:AclBackup ($name + '.sddl')
    if (-not (Test-Path -LiteralPath $bak)) { return $true }    # 没锁过
    $sub = "SYSTEM\CurrentControlSet\Services\$name"
    $err = ''

    # 先试简单路径: 直接按备份 SDDL 写回
    if ([LiquidWU.AclFixer]::SetDaclFromSddl($sub, (Get-Content -LiteralPath $bak -Raw).Trim(), [ref]$err)) {
        Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
        Write-Log ("  已解锁 {0}" -f $name) 'Ok'
        return $true
    }

    # 失败 -> 抢所有权再写
    Write-Log ("  直接解锁失败({0}), 尝试获取所有权..." -f $err) 'Warn'
    if (-not [LiquidWU.AclFixer]::TakeOwnership($sub, [ref]$err)) {
        Write-Log ("  获取所有权失败: {0}" -f $err) 'Err'
        return $false
    }
    if ([LiquidWU.AclFixer]::SetDaclFromSddl($sub, (Get-Content -LiteralPath $bak -Raw).Trim(), [ref]$err)) {
        Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
        Write-Log ("  已解锁(经获取所有权) {0}" -f $name) 'Ok'
        return $true
    }
    Write-Log ("  还原 DACL 仍失败: {0}" -f $err) 'Err'
    return $false
}

function Repair-AllServiceAcls {
    Write-Log '修复历史遗留的服务键 ACL 锁定' 'Info'
    $ok = 0; $skip = 0; $fail = 0
    foreach ($n in $script:SvcCore) {
        $bak = Join-Path $script:AclBackup ($n + '.sddl')
        if (-not (Test-Path -LiteralPath $bak)) { $skip++; continue }
        if (Repair-ServiceKeyAcl $n) { $ok++ } else { $fail++ }
    }
    Write-Log ("  已修复 {0} / 跳过 {1}(没锁过) / 失败 {2}" -f $ok, $skip, $fail) 'Ok'
    # 复核: 用 SCM 判断, 不依赖注册表读权限
    foreach ($n in $script:SvcCore) {
        $st = Get-SvcStartType $n
        Write-Log ("    {0,-15} SCM 启动类型 = {1}" -f $n, (Get-SvcStartText $st))
    }
    return $fail
}

# =====================================================================
#  主流程
# =====================================================================

function Invoke-Disable {
    Initialize-Dirs
    Update-Bar 2 '准备'
    Write-Log '========== 开始禁用 Windows 更新 ==========' 'Info'
    Update-Bar 8 '记录基线'
    Save-Baseline

    Update-Bar 14 '清理上次的锁定'
    Write-Log '第 1 步: 清理上次遗留的锁定' 'Info'
    $null = Repair-AllServiceAcls

    Update-Bar 20 '写入组策略'
    Write-Log '第 2 步: 写入组策略(这是真正长期有效的部分)' 'Info'
    Set-WuPolicy $true
    Set-StorePolicy $true

    Update-Bar 26 '停止更新服务'
    Write-Log '第 3 步: 先停止更新服务与修复进程' 'Info'
    Stop-AllServices 3
    Stop-UpdateProcesses
    Start-Sleep -Seconds 1

    Update-Bar 30 '禁用计划任务'
    Write-Log '第 4 步: 禁用更新相关计划任务' 'Info'
    $tasks = @(Get-UpdateTasks)
    $okT = 0; $failT = 0; $xmlT = 0
    $ti = 0
    foreach ($t in $tasks) {
        $ti++
        if ($tasks.Count -gt 0) {
            Update-Bar (30 + [int](25.0 * $ti / $tasks.Count)) ("禁用计划任务 {0}/{1}" -f $ti, $tasks.Count)
        }
        if (-not $t.Enabled) { $okT++; continue }
        $done = $false
        $code = 1
        $null = & schtasks.exe /change /tn ("`"{0}{1}`"" -f $t.TaskPath, $t.TaskName) /disable 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0) { $done = $true }
        if (-not $done) {
            if (Set-TaskXmlEnabled $t.TaskPath $t.TaskName $false) { $xmlT++; $done = $true }
        }
        if ($done) { $okT++ } else { $failT++; Write-Log ("  无法禁用: {0}{1}" -f $t.TaskPath, $t.TaskName) 'Warn' }
    }
    Write-Log ("  任务: 成功 {0} / XML改写 {1} / 失败 {2}" -f $okT, $xmlT, $failT) 'Ok'
    if ($xmlT -gt 0) {
        Update-Bar 56 '重载任务计划程序'
        if (-not (Restart-TaskScheduler)) {
            Write-Log '  !! 受保护任务的 XML 改动要等重启才生效, 重启前它们仍会运行' 'Err'
        }
    }

    Update-Bar 62 '设置服务启动类型'
    Write-Log '第 5 步: 将服务启动类型设为禁用(经 SCM)' 'Info'
    foreach ($n in $script:SvcCore) {
        if (Set-SvcStartMode $n 'disabled') { Write-Log ("  {0} : 已禁用" -f $n) 'Ok' }
        else { Write-Log ("  {0} : 修改失败" -f $n) 'Warn' }
    }

    Write-Log '第 6 步: 盯 30 秒, 复核是否被系统改回(校验走 SCM)' 'Info'
    $reverts = 0
    for ($i = 1; $i -le 10; $i++) {
        Update-Bar (66 + $i) ("复核中 {0}/30 秒" -f ($i * 3))
        Start-Sleep -Seconds 3
        $bad = @(Get-NonDisabledServices)
        if ($bad.Count -eq 0) { continue }
        $reverts++
        Write-Log ("  第 {0} 秒被改回: {1} (第 {2} 次)" -f ($i * 3), ($bad -join ', '), $reverts) 'Warn'
        foreach ($n in $script:SvcCore) { $null = Set-SvcStartMode $n 'disabled' }
    }
    if ($reverts -eq 0) { Write-Log '  30 秒内没有被改回' 'Ok' }

    Update-Bar 90 '收尾'
    Stop-AllServices 2
    Stop-UpdateProcesses
    Start-Sleep -Seconds 2

    $still = @(Get-NonDisabledServices)
    Update-Bar 100 '完成'
    Write-Log '' 'Info'
    if ($still.Count -eq 0) {
        Write-Log '==================== 禁用完成 ====================' 'Ok'
        Write-Log '  5 个更新服务均为禁用, 更新源已指向不存在的内网 WSUS' 'Ok'
    } else {
        Write-Log '==================== 部分完成 ====================' 'Warn'
        Write-Log ("  以下服务仍不是禁用: {0}" -f ($still -join ', ')) 'Err'
        Write-Log '  多数情况重启后即保持; 若反复出现请把日志发给作者' 'Warn'
    }
    Write-Log '  提示: 策略(假 WSUS + 禁连微软)是长期生效的部分, 服务被改回也不影响它' 'Warn'
    Write-Log '========== 禁用流程结束 ==========' 'Info'
    Complete-Bar
    return $still.Count
}

function Invoke-Restore {
    Initialize-Dirs
    Update-Bar 2 '准备'
    Write-Log '========== 开始恢复 Windows 更新 ==========' 'Info'

    Update-Bar 8 '解锁旧锁定'
    Write-Log '第 1 步: 解锁服务键 ACL(收拾旧版遗留)' 'Info'
    $null = Repair-AllServiceAcls

    Update-Bar 20 '还原服务启动类型'
    Write-Log '第 2 步: 按基线还原服务启动类型' 'Info'
    $baseMap = Get-BaselineMap
    foreach ($n in $script:SvcCore) {
        $st = $baseMap[$n][0]
        $dl = $baseMap[$n][1]
        $mode = 'demand'
        if ($st -eq 2) { if ($dl -eq 1) { $mode = 'delayed-auto' } else { $mode = 'auto' } }
        elseif ($st -eq 4) { $mode = 'disabled' }
        if (Set-SvcStartMode $n $mode) { Write-Log ("  {0} : 还原为 {1}" -f $n, $mode) 'Ok' }
        else { Write-Log ("  {0} : 修改失败" -f $n) 'Warn' }
    }

    Update-Bar 32 '删除组策略'
    Write-Log '第 3 步: 删除组策略(WindowsUpdate + Store)' 'Info'
    Set-WuPolicy $false
    Set-StorePolicy $false

    Update-Bar 40 '恢复计划任务'
    Write-Log '第 4 步: 恢复计划任务' 'Info'
    $tasks = @(Get-UpdateTasks)
    $okT = 0; $failT = 0; $bakT = 0; $changed = $false
    $ti = 0
    foreach ($t in $tasks) {
        $ti++
        if ($tasks.Count -gt 0) {
            Update-Bar (40 + [int](45.0 * $ti / $tasks.Count)) ("恢复计划任务 {0}/{1}" -f $ti, $tasks.Count)
        }
        if ($t.Enabled) { $okT++; continue }
        $done = $false
        $null = & schtasks.exe /change /tn ("`"{0}{1}`"" -f $t.TaskPath, $t.TaskName) /enable 2>&1
        if ($LASTEXITCODE -eq 0) { $done = $true }
        if (-not $done -and (Restore-TaskFromBackup $t.TaskPath $t.TaskName)) { $bakT++; $done = $true }
        if (-not $done -and (Set-TaskXmlEnabled $t.TaskPath $t.TaskName $true)) { $done = $true }
        if ($done) { $okT++ } else { $failT++ }
        $changed = $true
    }
    Write-Log ("  任务: 成功 {0} / 备份还原 {1} / 失败 {2}" -f $okT, $bakT, $failT) 'Ok'
    if ($changed) { $null = Restart-TaskScheduler }

    Update-Bar 90 '刷新策略'
    Write-Log '第 5 步: 刷新策略' 'Info'
    $null = & gpupdate.exe /force 2>&1
    Write-Log '  gpupdate /force 完成' 'Ok'

    Update-Bar 100 '完成'
    Write-Log '' 'Info'
    Write-Log '==================== 恢复完成 ====================' 'Ok'
    Write-Log '  服务已按基线还原, 组策略已删除, 计划任务已启用' 'Ok'
    Write-Log '  现在可以打开 设置 -> Windows 更新 -> 检查更新 验证' 'Warn'
    Write-Log '========== 恢复流程结束 ==========' 'Info'
    Complete-Bar
}

# =====================================================================
#  状态
# =====================================================================
function Show-Status {
    Write-Host ''
    Write-Host '--- 服务 (SCM 权威视图) ---' -ForegroundColor Cyan
    foreach ($n in $script:SvcCore) {
        $st = Get-SvcStartType $n
        $q = & sc.exe query $n 2>&1
        $state = if (($q -join ' ') -match 'RUNNING') { '运行中' } elseif (($q -join ' ') -match 'STOPPED') { '已停止' } else { '?' }
        $color = if ($st -eq 4) { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-15} 启动类型={1,-8} {2}" -f $n, (Get-SvcStartText $st), $state) -ForegroundColor $color
    }

    Write-Host '--- 组策略 ---' -ForegroundColor Cyan
    $au = Get-ItemProperty -Path $script:PolicyAU -ErrorAction SilentlyContinue
    $wu = Get-ItemProperty -Path $script:PolicyWU -ErrorAction SilentlyContinue
    $store = Get-ItemProperty -Path $script:PolicyStore -ErrorAction SilentlyContinue
    Write-Host ("  NoAutoUpdate        = {0}" -f $(if ($au) { $au.NoAutoUpdate } else { '未设置' }))
    Write-Host ("  UseWUServer         = {0}" -f $(if ($au) { $au.UseWUServer } else { '未设置' }))
    Write-Host ("  WUServer            = {0}" -f $(if ($wu) { $wu.WUServer } else { '未设置' }))
    Write-Host ("  禁连微软更新服务器  = {0}" -f $(if ($wu) { $wu.DoNotConnectToWindowsUpdateInternetLocations } else { '未设置' }))
    Write-Host ("  Store 自动更新      = {0}" -f $(if ($store) { if ($store.AutoDownload -eq 2) { '已关闭 (2)' } else { $store.AutoDownload } } else { '未设置' }))

    Write-Host '--- 计划任务 ---' -ForegroundColor Cyan
    foreach ($t in @(Get-UpdateTasks)) {
        $s = if ($t.Enabled) { '启用' } else { '禁用' }
        $c = if ($t.Enabled) { 'Yellow' } else { 'Green' }
        Write-Host ("  [{0}] {1}{2}" -f $s, $t.TaskPath, $t.TaskName) -ForegroundColor $c
    }

    Write-Host '--- 遗留 ACL 锁定 ---' -ForegroundColor Cyan
    $left = @()
    foreach ($n in $script:SvcCore) {
        if (Test-Path -LiteralPath (Join-Path $script:AclBackup ($n + '.sddl'))) { $left += $n }
    }
    if ($left.Count -eq 0) { Write-Host '  (无, 状态干净)' -ForegroundColor Green }
    else { Write-Host ("  以下服务键仍带旧版锁定, 建议运行菜单 4 修复: {0}" -f ($left -join ', ')) -ForegroundColor Yellow }

    Write-Host ''
    Write-Host ("日志: {0}" -f $script:LogFile) -ForegroundColor DarkGray
    Write-Host ''
}

# =====================================================================
#  入口
# =====================================================================
Initialize-Dirs

if ($Auto) {
    switch ($Auto) {
        'disable' { $null = Invoke-Disable }
        'restore' { Invoke-Restore }
        'status'  { Show-Status }
        'repair'  { $null = Repair-AllServiceAcls }
    }
    return
}

$running = $true
while ($running) {
    Write-Host ''
    Write-Host ' ============================================' -ForegroundColor Cyan
    Write-Host '   Windows 更新 禁用 / 恢复 工具  v2.0' -ForegroundColor Cyan
    Write-Host '   作者: Perlica' -ForegroundColor Cyan
    Write-Host ' ============================================' -ForegroundColor Cyan
    Write-Host '  1) 禁用 Windows 更新 (含 Store 应用自动更新)'
    Write-Host '  2) 恢复 Windows 更新'
    Write-Host '  3) 查看当前状态'
    Write-Host '  4) 修复旧版遗留的服务键 ACL 锁定'
    Write-Host '  0) 退出'
    Write-Host ''
    $choice = Read-Host '  请输入选项'
    switch ($choice) {
        '1' { $null = Invoke-Disable }
        '2' { Invoke-Restore }
        '3' { Show-Status }
        '4' { $null = Repair-AllServiceAcls }
        '0' { Write-Host '再见。'; $running = $false }
        default { Write-Host '  让你输0~4 你眼睛虾吗' -ForegroundColor Red }
    }
    if ($running -and $choice -in @('1', '2', '4')) { $null = Read-Host '按回车返回菜单' }
}

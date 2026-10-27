#requires -Version 5.1
<#
  Update Guard - PowerShell build
  Author: Perlica   License: MIT
#>

[CmdletBinding()]
param(
    [ValidateSet('', 'disable', 'restore', 'status')]
    [string]$Auto = '',

    # Show every step on the console instead of only the progress bar.
    [switch]$Detail
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

# ------------------------------------------------------------------ elevation
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
# Reading the status does not need admin rights.
$needsElevation = -not ($Auto -eq 'status')

if ((-not $isElevated) -and $needsElevation) {
    Write-Host 'Administrator rights are required. Requesting elevation (click Yes in the UAC prompt)...' -ForegroundColor Yellow
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ("`"$PSCommandPath`""))
    if ($Auto)   { $arguments += @('-Auto', $Auto) }
    if ($Detail) { $arguments += '-Detail' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments
    exit
}

# ------------------------------------------------------------------ constants
# dosvc (Delivery Optimization) is deliberately not managed: the SCM refuses to change its
# start type (ChangeServiceConfig -> access denied) and it plays no part in policy blocking.
$script:Services  = @('wuauserv', 'usosvc', 'WaaSMedicSvc', 'bits')
$script:StopOrder = @('usosvc', 'WaaSMedicSvc', 'wuauserv', 'bits')
$script:Processes = @('MoUsoCoreWorker', 'TiWorker', 'wuauclt', 'usoclient')

$script:TaskFolders = @(
    'C:\Windows\System32\Tasks\Microsoft\Windows\UpdateOrchestrator',
    'C:\Windows\System32\Tasks\Microsoft\Windows\WaaSMedic',
    'C:\Windows\System32\Tasks\Microsoft\Windows\WindowsUpdate',
    'C:\Windows\System32\Tasks\Microsoft\Windows\InstallService'
)
$script:TasksRoot = 'C:\Windows\System32\Tasks'
$script:TaskNs    = 'http://schemas.microsoft.com/windows/2004/02/mit/task'

$script:PolicyWu    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:PolicyAu    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:PolicyStore = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
$script:DeadWsus    = 'http://127.0.0.1:8530'

$script:DataDir    = Join-Path $env:ProgramData 'UpdateGuard'
$script:LogFile    = Join-Path $script:DataDir 'log.txt'
$script:Baseline   = Join-Path $script:DataDir 'services.txt'
$script:TaskBackup = Join-Path $script:DataDir 'tasks'

# The Schedule service does not grant Administrators SERVICE_STOP, so the right is
# added temporarily and the original SDDL is restored right after the reload.
$script:SddlNoStop   = 'CCLCSWRPDTLOCRRCWDWO;;;BA'
$script:SddlWithStop = 'CCLCSWRPWPDTLOCRRCWDWO;;;BA'

function Initialize-Directories {
    foreach ($dir in @($script:DataDir, $script:TaskBackup)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

# ------------------------------------------------------------------ logging
# Only warnings and errors reach the console; everything goes to the log file.
function Write-Log([string]$Message, [string]$Level = 'Info') {
    $tag = switch ($Level) {
        'Ok'    { '[ ok ]' }
        'Warn'  { '[warn]' }
        'Err'   { '[err ]' }
        default { '[info]' }
    }
    $line  = '{0}  {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $tag, $Message
    $color = switch ($Level) {
        'Ok'    { 'Green' }
        'Warn'  { 'Yellow' }
        'Err'   { 'Red' }
        default { 'Gray' }
    }

    if ($Detail -or $Level -eq 'Warn' -or $Level -eq 'Err') {
        Clear-Bar
        Write-Host $line -ForegroundColor $color
    }
    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

# ------------------------------------------------------------------ progress bar
# Drawn manually instead of using Write-Progress, which some hosts do not render.
$script:BarWidth = 0

function Update-Bar([int]$Percent, [string]$Stage) {
    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    $width  = 34
    $filled = [int][math]::Floor($width * $Percent / 100.0)
    if ($filled -lt 0)      { $filled = 0 }
    if ($filled -gt $width) { $filled = $width }

    $bar  = ('#' * $filled) + (' ' * ($width - $filled))
    $line = '  [{0}] {1,3}%  {2}' -f $bar, $Percent, $Stage
    if ($line.Length -lt $script:BarWidth) { $line = $line.PadRight($script:BarWidth) }
    $script:BarWidth = $line.Length

    try {
        [Console]::Write("`r" + $line)
    } catch {
        try { Write-Progress -Activity 'Update Guard' -Status $Stage -PercentComplete $Percent } catch { }
    }
}

function Clear-Bar {
    if ($script:BarWidth -gt 0) {
        try { [Console]::Write("`r" + (' ' * $script:BarWidth) + "`r") } catch { }
        $script:BarWidth = 0
    }
}

function Complete-Bar {
    try { [Console]::WriteLine() } catch { }
    $script:BarWidth = 0
}

# Run an external tool with a hard timeout. Returns the exit code, or -1 on timeout.
# Nothing in this script is allowed to block forever.
function Invoke-Process([string]$FilePath, [string]$Arguments, [int]$TimeoutMs = 20000) {
    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $FilePath
        $info.Arguments = $Arguments
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($info)
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch { }
            return -1
        }
        return $process.ExitCode
    } catch { return -1 }
}

# ------------------------------------------------------------------ services
# Read from the Service Control Manager, which keeps its own copy of the configuration.
function Get-ServiceStartType([string]$Name) {
    $output = & sc.exe qc $Name 2>&1
    if ($LASTEXITCODE -ne 0) { return -1 }
    foreach ($line in $output) {
        if ($line -match 'START_TYPE\s*:\s*(\d)') { return [int]$Matches[1] }
    }
    return -1
}

function Get-ServiceStartText([int]$Type) {
    switch ($Type) {
        2       { 'automatic' }
        3       { 'manual' }
        4       { 'disabled' }
        default { 'unknown' }
    }
}

function Set-ServiceStartType([string]$Name, [string]$Mode) {
    # $Mode: disabled / demand / auto / delayed-auto
    $output = & sc.exe config $Name start= $Mode 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }
    # Keep the real reason: "access denied" and "service is protected" need different fixes.
    $script:LastScError = ('sc config {0} start= {1} -> exit {2}: {3}' -f `
                           $Name, $Mode, $LASTEXITCODE, (($output -join ' ').Trim()))
    return $false
}

# The tray badge means one of two things: updates were downloaded and are waiting, or a
# restart is pending. Neither can install while the policy is in place, so drop both.
function Clear-PendingUpdateState {
    $rebootKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    try {
        if (Test-Path $rebootKey) {
            Remove-Item -Path $rebootKey -Recurse -Force -ErrorAction Stop
            Write-Log '  pending restart flag cleared' 'Ok'
        }
    } catch {
        Write-Log ('  could not clear the pending restart flag: ' + $_.Exception.Message) 'Warn'
    }

    # Deleting ~1 GB with Remove-Item -Recurse takes minutes: every locked file is retried.
    # rd /s /q is a single native pass and the timeout keeps it bounded.
    $download = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    if (Test-Path -LiteralPath $download) {
        $code = Invoke-Process 'cmd.exe' ('/c rd /s /q "{0}"' -f $download) 60000
        if ($code -eq 0) {
            Write-Log '  downloaded update payload removed' 'Ok'
        } else {
            Write-Log ('  partially cleared (exit {0}); the leftovers are harmless' -f $code) 'Warn'
        }
        if (-not (Test-Path -LiteralPath $download)) {
            $null = New-Item -ItemType Directory -Path $download -Force
        }
    }
}

function Stop-AllServices([int]$Rounds = 2, [int]$FromPercent = -1, [int]$ToPercent = -1) {
    for ($round = 1; $round -le $Rounds; $round++) {
        $running = @()
        foreach ($name in $script:StopOrder) {
            $query = & sc.exe query $name 2>&1
            if ($LASTEXITCODE -eq 0 -and -not (($query -join ' ') -match 'STOPPED')) { $running += $name }
        }
        if ($running.Count -eq 0) {
            Write-Log 'All update related services are stopped' 'Ok'
            return
        }
        Write-Log ('Stopping (round {0}): {1}' -f $round, ($running -join ', '))

        # Send every stop request first, then wait once for the whole group.
        # Waiting per service cost 8 s each, so a busy wuauserv alone stalled the run.
        foreach ($name in $running) { $null = & sc.exe stop $name 2>&1 }

        $deadline = (Get-Date).AddSeconds(12)
        $pending = $running
        while ((Get-Date) -lt $deadline -and $pending.Count -gt 0) {
            Start-Sleep -Milliseconds 600
            $pending = @($pending | Where-Object {
                $q = & sc.exe query $_ 2>&1
                $LASTEXITCODE -eq 0 -and -not (($q -join ' ') -match 'STOPPED')
            })
            if ($FromPercent -ge 0 -and $ToPercent -gt $FromPercent) {
                $portion = (($round - 1) + ($running.Count - $pending.Count) / [double]($running.Count + 1)) / $Rounds
                $label = if ($pending.Count -gt 0) { $pending[0] } else { 'services' }
                Update-Bar ($FromPercent + [int](($ToPercent - $FromPercent) * $portion)) ("Stopping {0}" -f $label)
            }
        }

        foreach ($name in $running) {
            if ($pending -contains $name) {
                Write-Log ('  {0}: still running, it will stay down after a reboot' -f $name) 'Warn'
            } else {
                Write-Log ('  {0}: stopped' -f $name) 'Ok'
            }
        }

        if ($round -lt $Rounds) {
            Stop-UpdateProcesses
            Start-Sleep -Seconds 1
        }
    }
    Write-Log 'Some services are still running; they are disabled and will not start after a reboot' 'Warn'
}

function Stop-UpdateProcesses {
    foreach ($processName in $script:Processes) {
        Get-Process -Name $processName -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.Kill() } catch { }
        }
    }
    Write-Log 'Killed any leftover update processes' 'Ok'
}

# Services whose start type is not "disabled" (asked of the SCM, so no false positives).
function Get-NonDisabledServices {
    $result = @()
    foreach ($name in $script:Services) {
        $type = Get-ServiceStartType $name
        if ($type -ne 4) { $result += ('{0} ({1})' -f $name, (Get-ServiceStartText $type)) }
    }
    return $result
}

# ------------------------------------------------------------------ policies
function Set-WindowsUpdatePolicy([bool]$Enable) {
    try {
        if ($Enable) {
            if (-not (Test-Path $script:PolicyWu)) { New-Item -Path $script:PolicyWu -Force | Out-Null }
            New-ItemProperty -Path $script:PolicyWu -Name 'WUServer' -Value $script:DeadWsus -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $script:PolicyWu -Name 'WUStatusServer' -Value $script:DeadWsus -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $script:PolicyWu -Name 'DoNotConnectToWindowsUpdateInternetLocations' -Value 1 -PropertyType DWord -Force | Out-Null

            if (-not (Test-Path $script:PolicyAu)) { New-Item -Path $script:PolicyAu -Force | Out-Null }
            New-ItemProperty -Path $script:PolicyAu -Name 'NoAutoUpdate' -Value 1 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $script:PolicyAu -Name 'UseWUServer' -Value 1 -PropertyType DWord -Force | Out-Null

            Write-Log ('Policy: update source -> {0}, internet updates blocked, NoAutoUpdate=1' -f $script:DeadWsus) 'Ok'
        } else {
            Remove-Item -Path $script:PolicyWu -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log 'Policy: all Windows Update policies removed' 'Ok'
        }
    } catch {
        Write-Log ('Failed to write Windows Update policy: ' + $_.Exception.Message) 'Err'
    }
}

function Set-StorePolicy([bool]$Enable) {
    try {
        if ($Enable) {
            if (-not (Test-Path $script:PolicyStore)) { New-Item -Path $script:PolicyStore -Force | Out-Null }
            # WindowsStore.admx: policy DisableAutoDownloadWin8, enabled = 2, disabled = 3
            New-ItemProperty -Path $script:PolicyStore -Name 'AutoDownload' -Value 2 -PropertyType DWord -Force | Out-Null
            Write-Log 'Policy: Microsoft Store app auto-update disabled (WindowsStore\AutoDownload=2)' 'Ok'
        } else {
            try {
                $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                            'SOFTWARE\Policies\Microsoft\WindowsStore', $true)
                if ($key) {
                    $key.DeleteValue('AutoDownload', $false)
                    $isEmpty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0)
                    $key.Close()
                    if ($isEmpty) {
                        [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKey(
                            'SOFTWARE\Policies\Microsoft\WindowsStore', $false)
                    }
                }
            } catch { }
            Write-Log 'Policy: Microsoft Store auto-update setting restored' 'Ok'
        }
    } catch {
        Write-Log ('Failed to write Store policy: ' + $_.Exception.Message) 'Err'
    }
}

# ------------------------------------------------------------------ scheduled tasks
function Get-UpdateTasks {
    $tasks = @()
    foreach ($folder in $script:TaskFolders) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }

        $files = @()
        try {
            $files = Get-ChildItem -LiteralPath $folder -File -Recurse -Force -ErrorAction SilentlyContinue
        } catch { continue }

        foreach ($file in $files) {
            $relative = $file.FullName.Substring($script:TasksRoot.Length)
            $splitAt  = $relative.LastIndexOf('\')
            if ($splitAt -lt 0) { continue }

            $taskPath = $relative.Substring(0, $splitAt + 1)
            $taskName = $relative.Substring($splitAt + 1)

            $tasks += [pscustomobject]@{
                FilePath = $file.FullName
                TaskPath = $taskPath
                TaskName = $taskName
                # File first, Task Scheduler as a fallback; $null means "could not tell".
                Enabled  = (Get-TaskEnabledState $taskPath $taskName $file.FullName)
            }
        }
    }
    return $tasks
}

function Read-TaskEnabled([string]$FilePath) {
    try {
        $document = New-Object System.Xml.XmlDocument
        $document.PreserveWhitespace = $true
        $document.Load($FilePath)

        $namespaces = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
        $namespaces.AddNamespace('t', $script:TaskNs)

        $settings = $document.SelectSingleNode('/t:Task/t:Settings', $namespaces)
        if (-not $settings) { return $true }

        $enabled = $settings.SelectSingleNode('t:Enabled', $namespaces)
        if (-not $enabled) { return $true }
        return ($enabled.InnerText.Trim() -ne 'false')
    } catch { return $null }        # unreadable: unknown, not "enabled"
}

# Ask the file first (fast), fall back to the Task Scheduler when the file cannot be read.
# Returns $null when neither source answers, so the caller never reports a made-up value.
function Get-TaskEnabledState([string]$TaskPath, [string]$TaskName, [string]$FilePath) {
    $fromFile = Read-TaskEnabled $FilePath
    if ($null -ne $fromFile) { return $fromFile }

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
        if ($task.State -eq 'Disabled') { return $false }
        if ($task.State -eq 'Ready' -or $task.State -eq 'Running') { return $true }
    } catch { }
    return $null
}

function Get-TaskBackupName([string]$TaskPath, [string]$TaskName) {
    return ($TaskPath.Trim('\') -replace '\\', '_') + '_' + $TaskName + '.xml'
}

function Grant-AdministratorsFullControl([string]$FilePath) {
    $null = & takeown.exe /F $FilePath /A 2>&1
    # Reset to inherited permissions first. An older build left Deny-write ACEs on some
    # task files, so schtasks reported success while silently failing to persist.
    $null = & icacls.exe $FilePath /reset 2>&1
    $null = & icacls.exe $FilePath /grant '*S-1-5-32-544:(F)' 2>&1
}

function Set-TaskXmlEnabled([string]$TaskPath, [string]$TaskName, [bool]$Enabled) {
    $filePath = "$($script:TasksRoot)$TaskPath$TaskName"
    if (-not (Test-Path -LiteralPath $filePath)) { return $false }

    $backup = Join-Path $script:TaskBackup (Get-TaskBackupName $TaskPath $TaskName)
    if (-not (Test-Path -LiteralPath $backup)) {
        try {
            Copy-Item -LiteralPath $filePath -Destination $backup -Force -ErrorAction Stop
        } catch {
            Write-Log ('  Backup failed, still editing: ' + $TaskName) 'Warn'
        }
    }

    Grant-AdministratorsFullControl $filePath

    try {
        $document = New-Object System.Xml.XmlDocument
        $document.PreserveWhitespace = $true
        $document.Load($filePath)

        $namespaces = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
        $namespaces.AddNamespace('t', $script:TaskNs)

        $settings = $document.SelectSingleNode('/t:Task/t:Settings', $namespaces)
        if (-not $settings) { return $false }

        # Only Settings/Enabled is touched; <Enabled> inside <Triggers> is left alone.
        $node = $settings.SelectSingleNode('t:Enabled', $namespaces)
        if (-not $node) {
            $node = $document.CreateElement('Enabled', $script:TaskNs)
            $null = $settings.AppendChild($node)
        }

        $wanted = if ($Enabled) { 'true' } else { 'false' }
        if ($node.InnerText.Trim() -ne $wanted) {
            $node.InnerText = $wanted
            $document.Save($filePath)
        }
        return $true
    } catch {
        Write-Log ('  XML edit failed for ' + $TaskName + ': ' + $_.Exception.Message) 'Warn'
        return $false
    }
}

function Restore-TaskFromBackup([string]$TaskPath, [string]$TaskName) {
    $backup = Join-Path $script:TaskBackup (Get-TaskBackupName $TaskPath $TaskName)
    if (-not (Test-Path -LiteralPath $backup)) { return $false }

    $target = "$($script:TasksRoot)$TaskPath$TaskName"
    if (-not (Test-Path -LiteralPath $target)) { return $false }

    try {
        Grant-AdministratorsFullControl $target
        Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

# Stop and start the Schedule service through sc.exe. Restart-Service waits on the
# service state indefinitely, which is how the restore used to hang at 40%.
function Restart-ScheduleService {
    $null = Invoke-Process 'sc.exe' 'stop Schedule' 25000
    Start-Sleep -Seconds 2
    return ((Invoke-Process 'sc.exe' 'start Schedule' 25000) -eq 0)
}

# Reload the Task Scheduler so the XML edits take effect immediately.
function Restart-TaskScheduler {
    if (Restart-ScheduleService) {
        Write-Log 'Task Scheduler reloaded' 'Ok'
        return $true
    }

    # Administrators hold WRITE_DAC but not SERVICE_STOP, so grant it temporarily.
    $original = ((& sc.exe sdshow Schedule 2>&1) -join '').Trim()
    if ($original -notmatch [regex]::Escape($script:SddlNoStop)) {
        Write-Log 'Unexpected SDDL on the Schedule service, leaving it untouched' 'Warn'
        return $false
    }

    $patched = $original -replace [regex]::Escape($script:SddlNoStop), $script:SddlWithStop
    $null = & sc.exe sdset Schedule $patched 2>&1

    $succeeded = $false
    try {
        $succeeded = Restart-ScheduleService
        if (-not $succeeded) { Write-Log 'Restart still failed after granting the right' 'Warn' }
    } finally {
        $null = & sc.exe sdset Schedule $original 2>&1
        Write-Log 'Schedule service SDDL restored' 'Ok'
    }
    return $succeeded
}

# ------------------------------------------------------------------ baseline
function Save-Baseline {
    Initialize-Directories
    if (Test-Path -LiteralPath $script:Baseline) { return }

    $builder = New-Object System.Text.StringBuilder
    foreach ($name in $script:Services) {
        $startType = Get-ServiceStartType $name
        if ($startType -eq 4) { $startType = -1 }        # already disabled -> unknown

        $delayed = -1
        try {
            $value = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$name" `
                        -Name DelayedAutoStart -ErrorAction SilentlyContinue).DelayedAutoStart
            if ($null -ne $value) { $delayed = [int]$value }
        } catch { }

        $null = $builder.AppendLine("$name=$startType,$delayed")
    }

    try {
        Set-Content -LiteralPath $script:Baseline -Value $builder.ToString() -Encoding UTF8
        Write-Log 'Service start type baseline recorded' 'Ok'
    } catch {
        Write-Log ('Failed to write the baseline: ' + $_.Exception.Message) 'Warn'
    }
}

function Get-BaselineMap {
    $defaults = @{
        wuauserv     = @(3, 0)
        WaaSMedicSvc = @(3, 0)
        usosvc       = @(2, 1)
        dosvc        = @(2, 1)
        bits         = @(2, 1)
    }

    $map = @{}
    if (Test-Path -LiteralPath $script:Baseline) {
        try {
            foreach ($line in Get-Content -LiteralPath $script:Baseline) {
                $equals = $line.IndexOf('=')
                if ($equals -le 0) { continue }

                $name  = $line.Substring(0, $equals).Trim()
                $parts = $line.Substring($equals + 1).Split(',')

                $startType = 0
                if (-not [int]::TryParse($parts[0].Trim(), [ref]$startType)) { continue }
                if ($startType -eq 4 -or $startType -le 0) { continue }

                $delayed = -1
                if ($parts.Length -gt 1) { [void][int]::TryParse($parts[1].Trim(), [ref]$delayed) }
                $map[$name] = @($startType, $delayed)
            }
        } catch {
            Write-Log 'Could not read the baseline, falling back to defaults' 'Warn'
        }
    }

    foreach ($name in $script:Services) {
        if (-not $map.ContainsKey($name)) { $map[$name] = $defaults[$name] }
    }
    return $map
}

# ------------------------------------------------------------------ main flows
function Invoke-Disable {
    Initialize-Directories
    Update-Bar 2 'Preparing'
    Write-Log '========== Disabling Windows Update =========='

    Update-Bar 8 'Recording baseline'
    Save-Baseline

    Update-Bar 20 'Writing policies'
    Set-WindowsUpdatePolicy $true
    Set-StorePolicy $true

    Update-Bar 26 'Stopping services'
    # Abort any running scan first: a busy 'checking for updates' keeps wuauserv alive.
    Stop-UpdateProcesses
    Stop-AllServices 2 26 34
    Update-Bar 34 'Clearing the update badge'
    Clear-PendingUpdateState
    Start-Sleep -Seconds 1

    Update-Bar 36 'Disabling scheduled tasks'
    $tasks = @(Get-UpdateTasks)
    $succeeded = 0; $failed = 0; $edited = 0
    $index = 0
    foreach ($task in $tasks) {
        $index++
        if ($tasks.Count -gt 0) {
            Update-Bar (36 + [int](20.0 * $index / $tasks.Count)) ("Disabling tasks {0}/{1}" -f $index, $tasks.Count)
        }
        if ($task.Enabled -eq $false) { $succeeded++; continue }

        $done = $false
        if ((Invoke-Process 'schtasks.exe' ("/change /tn `"{0}{1}`" /disable" -f $task.TaskPath, $task.TaskName)) -eq 0) {
            $done = $true
        }
        if (-not $done -and (Set-TaskXmlEnabled $task.TaskPath $task.TaskName $false)) {
            $edited++
            $done = $true
        }

        if ($done) { $succeeded++ }
        else {
            $failed++
            Write-Log ('  Could not disable: {0}{1}' -f $task.TaskPath, $task.TaskName) 'Warn'
        }
    }
    Write-Log ('Tasks: {0} ok / {1} edited via XML / {2} failed' -f $succeeded, $edited, $failed) 'Ok'

    if ($edited -gt 0) {
        Update-Bar 56 'Reloading Task Scheduler'
        if (-not (Restart-TaskScheduler)) {
            Write-Log 'XML edits will only take effect after a reboot' 'Err'
        }
    }

    Update-Bar 62 'Setting service start types'
    $unchangeable = @()
    $protected = @()
    foreach ($name in $script:Services) {
        if (Set-ServiceStartType $name 'disabled') {
            Write-Log ('  {0}: disabled' -f $name) 'Ok'
        } elseif ($script:LastScError -match 'exit 5|Access is denied') {
            # Windows protects a few services at the SCM level; nothing to fix there.
            $protected += $name
            Write-Log ('  {0}: protected by Windows, skipped' -f $name) 'Warn'
        } else {
            $unchangeable += $name
            Write-Log ('  {0}: could not be changed - {1}' -f $name, $script:LastScError) 'Warn'
        }
    }

    # Watch for a while: the servicing stack may revert the start types immediately.
    # Services that refused the very first change are not retried, otherwise the same
    # failure is reported ten times in a row.
    $reverts = 0
    for ($step = 1; $step -le 10; $step++) {
        Update-Bar (66 + $step) ("Verifying {0}/30 s" -f ($step * 3))
        Start-Sleep -Seconds 3

        $reverted = @(Get-NonDisabledServices | Where-Object { $unchangeable -notcontains ($_ -split ' ')[0] })
        if ($reverted.Count -eq 0) { continue }

        $reverts++
        Write-Log ('  Reverted after {0} s: {1} (attempt {2})' -f ($step * 3), ($reverted -join ', '), $reverts) 'Warn'
        foreach ($name in $script:Services) {
            if ($unchangeable -contains $name) { continue }
            $null = Set-ServiceStartType $name 'disabled'
        }
    }
    if ($reverts -eq 0) { Write-Log '  Nothing changed back within 30 s' 'Ok' }

    Update-Bar 90 'Finishing'
    Stop-AllServices 1 88 90
    Stop-UpdateProcesses
    Start-Sleep -Seconds 2

    $remaining = @(Get-NonDisabledServices | Where-Object { $protected -notcontains ($_ -split ' ')[0] })
    Update-Bar 100 'Done'
    Write-Log ''
    if ($remaining.Count -eq 0) {
        Write-Log '==================== Done ====================' 'Ok'
        Write-Log '  All managed services are disabled and the update source is unreachable' 'Ok'
    } else {
        Write-Log '==================== Partially done ====================' 'Warn'
        Write-Log ('  Still enabled: {0}' -f ($remaining -join ', ')) 'Err'
        Write-Log '  Usually settles after a reboot. The policies remain in place either way.' 'Warn'
    }
    Write-Log '========== Disable finished =========='
    Complete-Bar
    return $remaining.Count
}

function Invoke-Restore {
    Initialize-Directories
    Update-Bar 2 'Preparing'
    Write-Log '========== Restoring Windows Update =========='

    Update-Bar 20 'Restoring service start types'
    $baseline = Get-BaselineMap
    foreach ($name in $script:Services) {
        $startType = $baseline[$name][0]
        $delayed   = $baseline[$name][1]

        $mode = 'demand'
        if ($startType -eq 2) {
            if ($delayed -eq 1) { $mode = 'delayed-auto' } else { $mode = 'auto' }
        } elseif ($startType -eq 4) {
            $mode = 'disabled'
        }

        if (Set-ServiceStartType $name $mode) { Write-Log ('  {0}: restored to {1}' -f $name, $mode) 'Ok' }
        else                                  { Write-Log ('  {0}: could not be changed' -f $name) 'Warn' }
    }

    Update-Bar 32 'Removing policies'
    Set-WindowsUpdatePolicy $false
    Set-StorePolicy $false

    Update-Bar 40 'Restoring scheduled tasks'
    $tasks = @(Get-UpdateTasks)
    $succeeded = 0; $failed = 0; $fromBackup = 0
    $changed = $false
    $index = 0

    foreach ($task in $tasks) {
        $index++
        if ($tasks.Count -gt 0) {
            Update-Bar (40 + [int](45.0 * $index / $tasks.Count)) ("Restoring tasks {0}/{1}" -f $index, $tasks.Count)
        }
        if ($task.Enabled -eq $true) { $succeeded++; continue }

        $done = $false
        if ((Invoke-Process 'schtasks.exe' ("/change /tn `"{0}{1}`" /enable" -f $task.TaskPath, $task.TaskName)) -eq 0) {
            $done = $true
        }
        if (-not $done -and (Restore-TaskFromBackup $task.TaskPath $task.TaskName)) {
            $fromBackup++
            $done = $true
        }
        if (-not $done -and (Set-TaskXmlEnabled $task.TaskPath $task.TaskName $true)) { $done = $true }

        if ($done) { $succeeded++ } else { $failed++ }
        $changed = $true
    }
    Write-Log ('Tasks: {0} ok / {1} from backup / {2} failed' -f $succeeded, $fromBackup, $failed) 'Ok'
    if ($changed) { $null = Restart-TaskScheduler }

    Update-Bar 90 'Refreshing policy'
    $null = Invoke-Process 'gpupdate.exe' '/force' 120000
    Write-Log 'gpupdate /force completed' 'Ok'

    Update-Bar 100 'Done'
    Write-Log ''
    Write-Log '==================== Restore complete ====================' 'Ok'
    Write-Log '  Services restored from the baseline, policies removed, tasks re-enabled' 'Ok'
    Write-Log '  Open Settings -> Windows Update -> Check for updates to verify' 'Warn'
    Write-Log '========== Restore finished =========='
    Complete-Bar
}

# ------------------------------------------------------------------ status
function Show-Status {
    Write-Host ''
    Write-Host '--- Services (as reported by the SCM) ---' -ForegroundColor Cyan
    foreach ($name in $script:Services) {
        $startType = Get-ServiceStartType $name
        $query = & sc.exe query $name 2>&1
        if (($query -join ' ') -match 'RUNNING')     { $state = 'running' }
        elseif (($query -join ' ') -match 'STOPPED') { $state = 'stopped' }
        else                                         { $state = 'unknown' }

        $color = if ($startType -eq 4) { 'Green' } else { 'Yellow' }
        Write-Host ('  {0,-15} {1,-12} {2}' -f $name, (Get-ServiceStartText $startType), $state) -ForegroundColor $color
    }

    Write-Host '--- Policies ---' -ForegroundColor Cyan
    $au    = Get-ItemProperty -Path $script:PolicyAu -ErrorAction SilentlyContinue
    $wu    = Get-ItemProperty -Path $script:PolicyWu -ErrorAction SilentlyContinue
    $store = Get-ItemProperty -Path $script:PolicyStore -ErrorAction SilentlyContinue

    $storeText = 'not set'
    if ($store) {
        if ($store.AutoDownload -eq 2) { $storeText = 'disabled (2)' } else { $storeText = $store.AutoDownload }
    }

    Write-Host ('  NoAutoUpdate      = {0}' -f $(if ($au) { $au.NoAutoUpdate } else { 'not set' }))
    Write-Host ('  UseWUServer       = {0}' -f $(if ($au) { $au.UseWUServer } else { 'not set' }))
    Write-Host ('  WUServer          = {0}' -f $(if ($wu) { $wu.WUServer } else { 'not set' }))
    Write-Host ('  Internet blocked  = {0}' -f $(if ($wu) { $wu.DoNotConnectToWindowsUpdateInternetLocations } else { 'not set' }))
    Write-Host ('  Store auto-update = {0}' -f $storeText)

    Write-Host '--- Scheduled tasks ---' -ForegroundColor Cyan
    foreach ($task in @(Get-UpdateTasks)) {
        if ($null -eq $task.Enabled)      { $state = 'unknown '; $color = 'DarkGray' }
        elseif ($task.Enabled)            { $state = 'enabled '; $color = 'Yellow' }
        else                              { $state = 'disabled'; $color = 'Green' }
        Write-Host ('  [{0}] {1}{2}' -f $state, $task.TaskPath, $task.TaskName) -ForegroundColor $color
    }

    Write-Host ''
    Write-Host ('Log: {0}' -f $script:LogFile) -ForegroundColor DarkGray
    Write-Host ''
}

# ------------------------------------------------------------------ entry point
Initialize-Directories

if ($Auto) {
    switch ($Auto) {
        'disable' { $null = Invoke-Disable }
        'restore' { Invoke-Restore }
        'status'  { Show-Status }
    }
    return
}

$running = $true
while ($running) {
    Write-Host ''
    Write-Host ' ============================================' -ForegroundColor Cyan
    Write-Host '   Update Guard  -  Windows Update control' -ForegroundColor Cyan
    Write-Host '   Author: Perlica' -ForegroundColor Cyan
    Write-Host ' ============================================' -ForegroundColor Cyan
    Write-Host '  1) Disable Windows Update (and Store app auto-updates)'
    Write-Host '  2) Restore Windows Update'
    Write-Host '  3) Show current status'
    Write-Host '  0) Exit'
    Write-Host ''
    $choice = Read-Host '  Select an option'

    switch ($choice) {
        '1' { $null = Invoke-Disable }
        '2' { Invoke-Restore }
        '3' { Show-Status }
        '0' { Write-Host 'Bye.'; $running = $false }
        default { Write-Host '  Please choose 0-3' -ForegroundColor Red }
    }
    if ($running -and $choice -in @('1', '2')) { $null = Read-Host 'Press Enter to return to the menu' }
}

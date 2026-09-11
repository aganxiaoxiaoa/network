#Requires -Version 5.1
# ==============================================================================
# NetworkSafeRecovery.ps1
# 独立安全恢复入口 (与只读诊断入口 NetworkDiagnostics.ps1 完全分离)
#
# 经用户明确授权，本入口仅允许两项网络写操作：
#   1) 连接白名单内的 Wi-Fi 配置文件 (701 / 702)
#   2) 仅对已验证的物理无线网卡执行 ipconfig /renew
#
# 永久禁止: 修改代理、Winsock、TCP/IP Reset、注册表、Wi-Fi 配置文件增删改、
#           ipconfig /release、DNS 刷新、网卡启停、服务与计划任务变更、路由器配置。
#
# 退出码: 0 成功 | 1 环境或执行错误 | 2 全部尝试后仍不可用 | 3 用户取消
# ==============================================================================

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Recover', 'Status', 'Help')]
    [string]$Action = 'Recover',

    # 优先尝试的 Wi-Fi 配置文件；不指定时按配置默认 701 -> 702
    [ValidateSet('701', '702')]
    [string]$TargetProfile,

    # 多张无线网卡存在歧义时，用于明确指定其中之一 (只能从已识别的无线网卡中选择)
    [string]$InterfaceGuid,

    [ValidateRange(5, 300)]
    [int]$ConnectTimeoutSeconds = 0,

    [ValidateRange(5, 300)]
    [int]$DhcpWaitSeconds = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$AppDir = $PSScriptRoot
$ToolRoot = Split-Path -Parent $AppDir
$ModulesDir = Join-Path $AppDir 'modules'

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-SafeRecoveryHelp {
    Write-Host '独立安全网络恢复工具 使用帮助:' -ForegroundColor Cyan
    Write-Host '  -Action Recover                : 尝试恢复上网 (默认，需逐字输入 YES 确认)'
    Write-Host '  -Action Status                 : 纯只读预检，展示网卡、当前网络与恢复计划'
    Write-Host '  -Action Help                   : 显示本帮助'
    Write-Host '  -TargetProfile 701|702         : 指定优先尝试的配置文件 (默认 701，失败自动回退 702)'
    Write-Host '  -InterfaceGuid <GUID>          : 多张无线网卡时明确指定目标网卡'
    Write-Host '  -ConnectTimeoutSeconds <5-300> : 关联等待上限 (默认 20 秒)'
    Write-Host '  -DhcpWaitSeconds <5-300>       : DHCP 续租后等待上限 (默认 30 秒)'
    Write-Host '  -WhatIf                        : 只展示计划，不执行任何网络修改'
    Write-Host ''
    Write-Host '  允许的写操作只有两项: netsh wlan connect (仅 701/702) 与 ipconfig /renew (仅无线网卡)' -ForegroundColor Yellow
    Write-Host '  绝不修改: 代理 / Winsock / 注册表 / Wi-Fi 配置文件 / 网卡启停 / 服务 / 看门狗' -ForegroundColor Yellow
    Write-Host '  退出码: 0 成功 | 1 环境或执行错误 | 2 全部尝试后仍不可用 | 3 用户取消' -ForegroundColor Gray
}

if ($Action -eq 'Help') {
    Show-SafeRecoveryHelp
    exit 0
}

Import-Module (Join-Path $ModulesDir 'SafeRecoveryObservation.psm1') -Force
Import-Module (Join-Path $ModulesDir 'SafeRecoveryActions.psm1') -Force

# 恢复操作需要管理员权限 (ipconfig /renew)；只读预检不需要
if ($Action -eq 'Recover' -and -not (Test-IsAdmin)) {
    Write-Host '[提示] 执行 DHCP 续租需要管理员权限，正在请求 UAC 提权...' -ForegroundColor Yellow
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', "-File `"$PSCommandPath`"", '-Action Recover')
    if ($PSBoundParameters.ContainsKey('TargetProfile')) { $argumentList += "-TargetProfile $TargetProfile" }
    if ($PSBoundParameters.ContainsKey('InterfaceGuid')) { $argumentList += "-InterfaceGuid `"$InterfaceGuid`"" }
    if ($PSBoundParameters.ContainsKey('ConnectTimeoutSeconds')) { $argumentList += "-ConnectTimeoutSeconds $ConnectTimeoutSeconds" }
    if ($PSBoundParameters.ContainsKey('DhcpWaitSeconds')) { $argumentList += "-DhcpWaitSeconds $DhcpWaitSeconds" }
    if ($PSBoundParameters.ContainsKey('WhatIf')) { $argumentList += '-WhatIf' }

    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList ($argumentList -join ' ') -Verb RunAs -PassThru -Wait
        exit $process.ExitCode
    } catch {
        Write-Host '[中止] 未获得管理员权限，未执行任何网络修改。' -ForegroundColor Red
        exit 1
    }
}

# 与只读诊断工具共用同一把单实例锁，避免诊断与恢复同时操作同一张网卡
$script:MutexName = 'Local\PortableNetworkDiagnosis'
$script:CreatedNew = $false
$script:Mutex = $null
try {
    $script:Mutex = New-Object System.Threading.Mutex($true, $script:MutexName, [ref]$script:CreatedNew)
} catch {
    $script:Mutex = $null
}
if ($null -ne $script:Mutex -and -not $script:CreatedNew) {
    Write-Host '[中止] 检测到便携诊断或恢复工具的另一个实例正在运行，请先关闭它。' -ForegroundColor Yellow
    exit 1
}

$exitCode = 1
try {
    $config = Get-SafeRecoveryConfig -AppDir $AppDir

    $preferred = $null
    if ($PSBoundParameters.ContainsKey('TargetProfile')) { $preferred = $TargetProfile }
    $profileOrder = Get-SafeRecoveryProfileOrder -Config $config -PreferredProfile $preferred

    switch ($Action) {
        'Status' {
            $result = Get-SafeRecoveryPreflight -Config $config -ProfileOrder $profileOrder -InterfaceGuid $InterfaceGuid
            $exitCode = $result.ExitCode
        }

        'Recover' {
            $forward = @{
                'ToolRoot'     = $ToolRoot
                'Config'       = $config
                'ProfileOrder' = $profileOrder
            }
            if (-not [string]::IsNullOrWhiteSpace($InterfaceGuid)) { $forward['InterfaceGuid'] = $InterfaceGuid }
            if ($ConnectTimeoutSeconds -gt 0) { $forward['ConnectTimeoutSeconds'] = $ConnectTimeoutSeconds }
            if ($DhcpWaitSeconds -gt 0) { $forward['DhcpWaitSeconds'] = $DhcpWaitSeconds }
            if ($PSBoundParameters.ContainsKey('WhatIf')) { $forward['WhatIf'] = $WhatIfPreference }

            $result = Invoke-SafeNetworkRecovery @forward
            $exitCode = $result.ExitCode

            Write-Host ''
            if ($result.Succeeded) {
                Write-Host "[结果] 已恢复上网，当前使用配置文件: $($result.ProfileUsed)" -ForegroundColor Green
            } elseif ($exitCode -eq 3) {
                Write-Host '[结果] 已取消，网络设置未被修改。' -ForegroundColor Yellow
            } elseif ($exitCode -eq 2) {
                Write-Host '[结果] 恢复失败，网络仍不可用。已停止，不会执行任何其他修复手段。' -ForegroundColor Red
            } elseif ($exitCode -ne 0) {
                Write-Host '[结果] 未能执行恢复，请查看上方中止原因。' -ForegroundColor Red
            }
            if (-not [string]::IsNullOrWhiteSpace($result.LogPath)) {
                Write-Host "[日志] $($result.LogPath)" -ForegroundColor Gray
            }
        }
    }
} catch {
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    if ($null -ne $script:Mutex -and $script:CreatedNew) {
        $script:Mutex.ReleaseMutex()
        $script:Mutex.Dispose()
    }
}

exit $exitCode

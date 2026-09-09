#Requires -Version 5.1
# ==============================================================================
# NetworkDiagnostics.ps1
# Windows 10/11 便携网络只读诊断工具箱 (完全驻留于 U 盘独立安全版)
# 严禁任何状态修改、严禁拔插网卡、严禁重置协议栈、严禁修改代理
# 运行一次后退出，不包含常驻循环
# ==============================================================================

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Diagnose', 'FullHealth', 'Bundle', 'ExportDrivers', 'BackupDrivers', 'Menu', 'Help')]
    [string]$Action = 'Menu',
    [switch]$IncludeSensitiveNetworkData
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue

# 1. 本地单实例互斥锁 (防止重复打开)
$script:MutexName = 'Local\PortableNetworkDiagnosis'
$script:CreatedNew = $false
try {
    $script:Mutex = New-Object System.Threading.Mutex($true, $script:MutexName, [ref]$script:CreatedNew)
    if (-not $script:CreatedNew) {
        Write-Host "[提示] 另一个便携诊断工具实例正在运行，请勿重复打开。" -ForegroundColor Yellow
        return
    }
} catch { }

# 2. 动态加载模块
$AppDir = $PSScriptRoot
$ToolRoot = Split-Path -Parent $AppDir
$ModulesDir = Join-Path $AppDir "modules"

Import-Module (Join-Path $ModulesDir "NetworkInventory.psm1") -Force
Import-Module (Join-Path $ModulesDir "NetworkHealth.psm1") -Force
Import-Module (Join-Path $ModulesDir "DiagnosticArtifacts.psm1") -Force

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-RunDiagnosis {
    $cfg = Get-ToolConfig

    Write-Host "=======================================================================" -ForegroundColor Cyan
    Write-Host "                正在执行便携只读网络健康与配置诊断...                  " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan

    # 1. 本地看门狗互斥与状态检测
    Write-Host "[1/9] 本地网络看门狗安全互斥检测:" -ForegroundColor Yellow
    $wdStatus = Get-LocalWatchdogStatus
    if ($wdStatus.IsProtected) {
        Write-Host "   - 本地已有看门狗状态: 正在运行中 (计划任务: $($wdStatus.TaskState), PID: $($wdStatus.ProcessId))" -ForegroundColor Green
        Write-Host "   - [安全锁闭] 检测到本地已有网络看门狗。为了避免双重监控干扰，本 U 盘工具全面锁定为纯只读诊断模式。" -ForegroundColor Cyan
    } else {
        Write-Host "   - 未检测到运行中的本地看门狗进程或任务。" -ForegroundColor Gray
    }

    # 2. 默认路由与网关
    Write-Host "`n[2/9] 默认路由与下一跳网关探测:" -ForegroundColor Yellow
    $routeInfo = Get-DefaultRouteInfo
    if ($routeInfo.HasDefaultRoute) {
        Write-Host "   - 默认路由: 0.0.0.0/0 存在" -ForegroundColor Green
        Write-Host "   - 接口索引: $($routeInfo.InterfaceIndex) ($($routeInfo.InterfaceAlias))"
        Write-Host "   - 下一跳网关: $($routeInfo.NextHop)"
        Write-Host "   - 有效跃点 (Metric): $($routeInfo.EffectiveMetric) (Route: $($routeInfo.RouteMetric) + Intf: $($routeInfo.InterfaceMetric))"
    } else {
        Write-Host "   - [警告] 未检测到有效的 IPv4 默认路由 (0.0.0.0/0)" -ForegroundColor Red
    }

    # 3. 物理适配器核验
    Write-Host "`n[3/9] 活动网络适配器核验:" -ForegroundColor Yellow
    $nicIndex = if ($routeInfo.HasDefaultRoute) { [int]$routeInfo.InterfaceIndex } else { 0 }
    $nic = Get-ActivePhysicalAdapter -PreferredInterfaceIndex $nicIndex
    if ($nic.Found) {
        $color = if ($nic.Status -eq 'Up') { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-Host "   - 适配器名称: $($nic.Name)" -ForegroundColor $color
        Write-Host "   - 硬件型号/描述: $($nic.InterfaceDescription)"
        Write-Host "   - 物理硬件 (HardwareInterface): $($nic.HardwareInterface)"
        Write-Host "   - 链路状态: $($nic.Status) (速度: $($nic.LinkSpeed))"
        Write-Host "   - MAC 地址: $($nic.MacAddress)"
        Write-Host "   - 承载默认路由: $(if ($nic.IsDefaultRouteOwner) { '是' } else { '否 (可能由 VPN/虚拟接口或备用网卡承载)' })"
    } else {
        Write-Host "   - [警告] 未找到符合条件的活动物理网络适配器！" -ForegroundColor Red
    }

    # 4. IP 与 DHCP 检查
    Write-Host "`n[4/9] IP 配置与 DHCP 分配:" -ForegroundColor Yellow
    $ipDetails = if ($nic.Found) { Get-AdapterIpDetails -InterfaceIndex $nic.InterfaceIndex } else { Get-AdapterIpDetails -InterfaceIndex 0 }
    if ($ipDetails.IPv4Address) {
        if ($ipDetails.IsApipa) {
            Write-Host "   - 当前 IPv4 地址: $($ipDetails.IPv4Address) [严重警告: APIPA 私有保留地址 169.254.x.x，表明未获得路由器 DHCP 分配]" -ForegroundColor Red
        } else {
            Write-Host "   - 当前 IPv4 地址: $($ipDetails.IPv4Address)" -ForegroundColor Green
        }
    } else {
        Write-Host "   - 未分配 IPv4 地址" -ForegroundColor Yellow
    }
    Write-Host "   - DHCP 状态: $(if ($ipDetails.DhcpEnabled) { '已启用 (动态获取)' } else { '已禁用 (静态配置或受控网络)' })"
    Write-Host "   - DNS 服务器: $(if ($ipDetails.DnsServers.Count -gt 0) { $ipDetails.DnsServers -join ', ' } else { '[无 DNS 服务器配置]' })"

    # 5. 网关连通性 (ICMP Ping, 仅作参考)
    Write-Host "`n[5/9] 动态网关连通性 (参考信号):" -ForegroundColor Yellow
    $gwTest = Test-DynamicGateway -Gateway $routeInfo.NextHop
    if ($gwTest.PingOk) {
        Write-Host "   - 网关 ($($gwTest.Gateway)) ICMP 连通: 正常响应" -ForegroundColor Green
    } else {
        Write-Host "   - 网关 ($($gwTest.Gateway)) ICMP 连通: $($gwTest.Note)" -ForegroundColor Yellow
    }

    # 6. 公网直连 TCP 握手探测 (绕过代理直连)
    Write-Host "`n[6/9] 公网直连 TCP 握手 (绕过系统代理，4 个不同运营商/端口目标):" -ForegroundColor Yellow
    $tcpProbe = Test-RawTcpTargets -Targets $cfg.PublicWanTargets -TimeoutMs $cfg.TcpProbeTimeoutMs
    foreach ($d in $tcpProbe.Details) {
        $tColor = if ($d.Connected) { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
        $tSymbol = if ($d.Connected) { "[√] 正常通畅" } else { "[×] 连接超时" }
        Write-Host ("   - 目标 {0,-22} : {1,-10} ({2} ms)" -f $d.Target, $tSymbol, $d.ElapsedMs) -ForegroundColor $tColor
    }
    if ($tcpProbe.WanReachable) {
        Write-Host "   => 公网链路判断: 广域网直连通畅 (至少 1 个独立目标成功握手)" -ForegroundColor Green
    } else {
        Write-Host "   => 公网链路判断: [警告] 所有公网直连目标均无法握手 (物理断网或局域网被严密隔离)" -ForegroundColor Red
    }

    # 7. DNS 域名解析
    Write-Host "`n[7/9] 域名系统 (DNS) 解析测试:" -ForegroundColor Yellow
    $dnsProbe = Test-DnsResolution -Domain $cfg.DnsTestDomain
    if ($dnsProbe.Resolves) {
        Write-Host "   - 测试域名: $($dnsProbe.Domain) -> 解析为: $($dnsProbe.Addresses)" -ForegroundColor Green
    } else {
        Write-Host "   - 测试域名: $($dnsProbe.Domain) -> 解析失败: $($dnsProbe.Error)" -ForegroundColor Red
    }

    # 8. 代理配置只读检查
    Write-Host "`n[8/9] 系统代理配置 (WinINET / WinHTTP 只读):" -ForegroundColor Yellow
    $proxy = Get-ProxyStatus
    if ($proxy.WinInet) {
        $pEnable = ($proxy.WinInet.ProxyEnable -eq 1)
        $pColor = if ($pEnable) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green }
        $pText  = if ($pEnable) { '已启用 [开启]' } else { '已关闭 [直连]' }
        Write-Host "   - 当前用户 WinINET 代理开关: $pText" -ForegroundColor $pColor
        if ($proxy.WinInet.ProxyServer) { Write-Host "   - 手动代理服务器 (ProxyServer): $($proxy.WinInet.ProxyServer)" }
        if ($proxy.WinInet.AutoConfigURL) { Write-Host "   - 自动配置 PAC 脚本 (AutoConfigURL): $($proxy.WinInet.AutoConfigURL)" }
        if ($proxy.WinInet.ProxyOverride) { Write-Host "   - 代理绕行规则 (ProxyOverride): $($proxy.WinInet.ProxyOverride)" }
    }
    Write-Host "   - 系统级 WinHTTP 代理状态 (只读):"
    $winHttpLines = $proxy.WinHttp -split "`n"
    foreach ($line in $winHttpLines) {
        Write-Host "     $line" -ForegroundColor Gray
    }

    # 9. 核心网络服务状态
    Write-Host "`n[9/9] Windows 核心网络服务状态:" -ForegroundColor Yellow
    $services = Get-NetworkServiceStatus -ServiceNames $cfg.CoreNetworkServices
    foreach ($s in $services) {
        $sColor = if ($s.Status -eq 'Running') { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-Host ("   - 服务 {0,-12} ({1,-20}): {2,-10} (启动类型: {3})" -f $s.Name, $s.DisplayName, $s.Status, $s.StartType) -ForegroundColor $sColor
    }

    Write-Host "`n=======================================================================" -ForegroundColor Cyan
    Write-Host "                      只读诊断完成                                     " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan
}

try {
    switch ($Action) {
        { $_ -in @('Diagnose', 'FullHealth') } {
            Invoke-RunDiagnosis
        }

        'Bundle' {
            $fwd = @{}
            if ($PSBoundParameters.ContainsKey('WhatIf')) { $fwd['WhatIf'] = $WhatIfPreference }
            New-DiagnosticBundle -ToolRoot $ToolRoot -IncludeWlanReport:$IncludeSensitiveNetworkData @fwd
        }

        { $_ -in @('ExportDrivers', 'BackupDrivers') } {
            if (-not (Test-IsAdmin)) {
                Write-Host "[提示] 导出驱动需要管理员权限，正在请求 UAC 提权..." -ForegroundColor Yellow
                $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File `"$PSCommandPath`"", "-Action ExportDrivers")
                if ($PSBoundParameters.ContainsKey('WhatIf')) { $argList += "-WhatIf" }
                $p = Start-Process -FilePath "powershell.exe" -ArgumentList ($argList -join ' ') -Verb RunAs -PassThru -Wait
                exit $p.ExitCode
            }
            $fwd = @{}
            if ($PSBoundParameters.ContainsKey('WhatIf')) { $fwd['WhatIf'] = $WhatIfPreference }
            Export-NetworkDrivers -ToolRoot $ToolRoot @fwd
        }

        'Help' {
            Write-Host "便携网络诊断工具箱使用帮助:" -ForegroundColor Cyan
            Write-Host "  -Action FullHealth / Diagnose  : 执行纯只读网络健康诊断并输出控制台"
            Write-Host "  -Action Bundle                 : 采集脱敏日志并打包为 output\*.zip"
            Write-Host "  -Action BackupDrivers          : 使用 PnPUtil 只读备份驱动至 backups\Drivers"
            Write-Host "  -Action Menu                   : 打开交互式主菜单 (默认)"
            Write-Host "  -IncludeSensitiveNetworkData   : 包含完整 WLAN 与未脱敏数据"
        }

        'Menu' {
            while ($true) {
                Clear-Host
                $adminColor = if (Test-IsAdmin) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
                $adminText  = if (Test-IsAdmin) { '是 [Administrator]' } else { '否 [Standard User]' }

                Write-Host "=======================================================================" -ForegroundColor Cyan
                Write-Host "        Windows 10/11 便携网络诊断工具箱 (USB 纯只读安全版)            " -ForegroundColor Cyan
                Write-Host "=======================================================================" -ForegroundColor Cyan
                Write-Host " 运行目录: $ToolRoot" -ForegroundColor Gray
                Write-Host " 管理员权限: $adminText" -ForegroundColor $adminColor
                Write-Host " [安全状态] 本工具已永久移除任何网络重置、网卡重启、DNS/DHCP 或代理修改指令！`n" -ForegroundColor Green

                Write-Host "   [1] 执行完整只读网络健康诊断 (路由 / 网关 / TCP / DNS / 代理 / 服务)" -ForegroundColor White
                Write-Host "   [2] 生成诊断报告与脱敏压缩包 (仅收集只读信息，安全脱敏)" -ForegroundColor White
                Write-Host "   [3] 导出第三方网络硬件驱动 (仅 PnPUtil 备份至 U 盘，不安装、不删除)" -ForegroundColor White
                Write-Host "   [0] 退出工具箱" -ForegroundColor Gray
                Write-Host "=======================================================================" -ForegroundColor Cyan
                Write-Host "请输入选项数字 [0-3]: " -ForegroundColor Yellow -NoNewline
                $choice = Read-Host

                switch ($choice.Trim()) {
                    '1' { Invoke-RunDiagnosis; Write-Host "`n按回车键返回菜单..."; Read-Host | Out-Null }
                    '2' {
                        Write-Host "是否在诊断包中包含完整 WLAN 报告？(可能包含历史 SSID 与硬件 MAC) [y/N]: " -ForegroundColor Yellow -NoNewline
                        $wlanChoice = Read-Host
                        $incWlan = ($wlanChoice.Trim() -eq 'y' -or $wlanChoice.Trim() -eq 'Y')
                        New-DiagnosticBundle -ToolRoot $ToolRoot -IncludeWlanReport:$incWlan
                        Write-Host "`n按回车键返回菜单..."; Read-Host | Out-Null
                    }
                    '3' {
                        if (-not (Test-IsAdmin)) {
                            Write-Host "[提示] 导出驱动需要管理员权限，正在请求 UAC 提权..." -ForegroundColor Yellow
                            Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action ExportDrivers" -Verb RunAs -Wait
                        } else {
                            Export-NetworkDrivers -ToolRoot $ToolRoot
                        }
                        Write-Host "`n按回车键返回菜单..."; Read-Host | Out-Null
                    }
                    '0' { break }
                    default {
                        Write-Host "无效选项，请重新输入。" -ForegroundColor Red
                        Start-Sleep -Seconds 1
                    }
                }
            }
        }
    }
} finally {
    if ($script:Mutex) {
        $script:Mutex.ReleaseMutex()
        $script:Mutex.Dispose()
    }
}

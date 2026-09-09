#Requires -Version 5.1
# ==============================================================================
# NetworkDiagnostics.ps1
# Windows 10/11 便携网络只读诊断工具箱 (完全驻留于 U 盘独立安全版)
# 严禁任何状态修改、严禁拔插网卡、严禁重置协议栈、严禁修改代理
# 运行一次后退出，不包含常驻循环
# ==============================================================================

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Diagnose', 'FullHealth', 'Bundle', 'ExportDrivers', 'BackupDrivers', 'Menu', 'Help', 'Timeline', 'SaveBaseline', 'CompareBaseline')]
    [string]$Action = 'Menu',
    [string]$BaselineFile = $null,
    [int]$HoursBack = 0,
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
Import-Module (Join-Path $ModulesDir "NetworkBaseline.psm1") -Force

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
    Write-Host "[1/12] 本地网络看门狗安全互斥检测:" -ForegroundColor Yellow
    $wdStatus = Get-LocalWatchdogStatus
    if ($wdStatus.IsProtected) {
        Write-Host "   - 本地已有看门狗状态: 正在运行中 (计划任务: $($wdStatus.TaskState), PID: $($wdStatus.ProcessId))" -ForegroundColor Green
        Write-Host "   - 代理进程 (Clash/ProxyStack) 数量: $($wdStatus.ProxyStackCount)" -ForegroundColor Gray
        Write-Host "   - [安全锁闭] 检测到本地已有网络看门狗。为了避免双重监控干扰，本 U 盘工具全面锁定为纯只读诊断模式。" -ForegroundColor Cyan
    } else {
        Write-Host "   - 未检测到运行中的本地看门狗进程或任务。" -ForegroundColor Gray
    }

    # 2. IPv4 默认路由与网关
    Write-Host "`n[2/12] IPv4 默认路由与下一跳网关探测:" -ForegroundColor Yellow
    $routeInfo = Get-DefaultRouteInfo
    if ($routeInfo.HasDefaultRoute) {
        Write-Host "   - 默认路由: 0.0.0.0/0 存在" -ForegroundColor Green
        Write-Host "   - 接口索引: $($routeInfo.InterfaceIndex) ($($routeInfo.InterfaceAlias))"
        Write-Host "   - 下一跳网关: $($routeInfo.NextHop)"
        Write-Host "   - 有效跃点 (Metric): $($routeInfo.EffectiveMetric) (Route: $($routeInfo.RouteMetric) + Intf: $($routeInfo.InterfaceMetric))"
    } else {
        Write-Host "   - [警告] 未检测到有效的 IPv4 默认路由 (0.0.0.0/0)" -ForegroundColor Red
    }

    # 3. IPv6 默认路由与双栈状态检测 (新增能力 1)
    Write-Host "`n[3/12] IPv6 默认路由与双栈状态检测:" -ForegroundColor Yellow
    $nicIndex = if ($routeInfo.HasDefaultRoute) { [int]$routeInfo.InterfaceIndex } else { 0 }
    $v6Info = Get-IPv6Status -PreferredInterfaceIndex $nicIndex
    if ($v6Info.HasDefaultRoute) {
        Write-Host "   - IPv6 默认路由: ::/0 存在" -ForegroundColor Green
        Write-Host "   - 接口索引: $($v6Info.InterfaceIndex) ($($v6Info.InterfaceAlias))"
        Write-Host "   - 下一跳网关: $($v6Info.NextHop)"
        Write-Host "   - 有效跃点 (Metric): $($v6Info.EffectiveMetric) (Route: $($v6Info.RouteMetric) + Intf: $($v6Info.InterfaceMetric))"
        if (@($v6Info.GlobalAddresses).Count -gt 0) {
            Write-Host "   - 全球单播 IPv6 地址 (GUA): $(@($v6Info.GlobalAddresses) -join ', ')" -ForegroundColor Green
        }
        Write-Host "   - 双栈状态判定: IPv4/IPv6 双栈路由均配置完整" -ForegroundColor Cyan
    } else {
        Write-Host "   - IPv6 默认路由: 未配置默认路由 (::/0 不存在)" -ForegroundColor Gray
        if (@($v6Info.GlobalAddresses).Count -gt 0) {
            Write-Host "   - 虽分配有公网 IPv6 地址 ($(@($v6Info.GlobalAddresses) -join ', '))，但无默认网关路由" -ForegroundColor Yellow
        }
        if ($routeInfo.HasDefaultRoute) {
            Write-Host "   - 双栈状态判定: 当前网络运行在纯 IPv4 单栈模式 (无 IPv6 默认网关，不会发生 IPv6 双栈黑洞超时)" -ForegroundColor Green
        } else {
            Write-Host "   - 双栈状态判定: [严重] IPv4 与 IPv6 默认路由均不存在 (彻底断网)" -ForegroundColor Red
        }
    }

    # 4. 活动网络适配器核验与电源管理 (新增能力 2)
    Write-Host "`n[4/12] 活动网络适配器核验与硬件电源管理:" -ForegroundColor Yellow
    $nic = Get-ActivePhysicalAdapter -PreferredInterfaceIndex $nicIndex
    if ($nic.Found) {
        $color = if ($nic.Status -eq 'Up') { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-Host "   - 适配器名称: $($nic.Name)" -ForegroundColor $color
        Write-Host "   - 硬件型号/描述: $($nic.InterfaceDescription)"
        Write-Host "   - 物理硬件 (HardwareInterface): $($nic.HardwareInterface)"
        Write-Host "   - 链路状态: $($nic.Status) (速度: $($nic.LinkSpeed))"
        Write-Host "   - MAC 地址: $($nic.MacAddress)"
        Write-Host "   - 承载默认路由: $(if ($nic.IsDefaultRouteOwner) { '是' } else { '否 (可能由 VPN/虚拟接口或备用网卡承载)' })"

        # 只读读取网卡电源管理设置
        $pmStatus = Get-AdapterPowerManagementStatus -AdapterName $nic.Name
        if ($pmStatus.PowerSavingEnabled) {
            Write-Host "   - 硬件节能状态: [警告] 允许计算机关闭此设备以节约电源 (Enabled)" -ForegroundColor Red
            Write-Host "     $($pmStatus.Note)" -ForegroundColor Yellow
        } else {
            Write-Host "   - 硬件节能状态: $($pmStatus.AllowTurnOffDevice) ($($pmStatus.Note))" -ForegroundColor Gray
        }
    } else {
        Write-Host "   - [警告] 未找到符合条件的活动物理网络适配器！" -ForegroundColor Red
    }

    # 5. 无线链路质量 (RSSI / 信号 / 信道 / 频段 / 协商速率) (新增能力 3)
    Write-Host "`n[5/12] 无线链路质量指标 (RSSI / 信道 / 协商速率):" -ForegroundColor Yellow
    $wlanQuality = Get-WlanLinkQuality
    if ($wlanQuality.Available) {
        Write-Host "   - 无线连接状态: $($wlanQuality.State)" -ForegroundColor Green
        Write-Host "   - SSID (脱敏): $($wlanQuality.SSID)"
        Write-Host "   - BSSID (脱敏): $($wlanQuality.BSSID)"
        Write-Host "   - 无线电类型: $($wlanQuality.RadioType) | 频段: $($wlanQuality.Band) | 工作信道: $($wlanQuality.Channel)"
        Write-Host "   - 协商速率: 接收 $($wlanQuality.ReceiveRate) Mbps / 传输 $($wlanQuality.TransmitRate) Mbps"
        $sigColor = if ($wlanQuality.SignalPercent -ge 70) { [ConsoleColor]::Green } elseif ($wlanQuality.SignalPercent -ge 50) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Red }
        Write-Host "   - 信号强度: $($wlanQuality.SignalPercent)% (估算 RSSI: $($wlanQuality.RssiEstimated) dBm)" -ForegroundColor $sigColor
        Write-Host "   - 链路质量评估: $($wlanQuality.Note)" -ForegroundColor Gray
    } else {
        Write-Host "   - 状态/说明: $($wlanQuality.Note)" -ForegroundColor Gray
    }

    # 6. IP 配置与 DHCP 租约详细信息 (新增能力 4 + Bug 2 修复)
    Write-Host "`n[6/12] IP 配置与 DHCP 租约详细信息:" -ForegroundColor Yellow
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
    # Bug 2 修复: @($ipDetails.DnsServers).Count
    Write-Host "   - DNS 服务器: $(if (@($ipDetails.DnsServers).Count -gt 0) { $ipDetails.DnsServers -join ', ' } else { '[无 DNS 服务器配置]' })"

    # 读取 DHCP 租约生命周期详情
    $dhcpLease = Get-DhcpLeaseInfo
    if ($dhcpLease.DhcpActive) {
        Write-Host "   - DHCP 路由器/服务器: $($dhcpLease.DHCPServer)"
        Write-Host "   - 租约获取时间: $($dhcpLease.LeaseObtained)"
        Write-Host "   - 租约到期时间: $($dhcpLease.LeaseExpires)"
        $remColor = if ($dhcpLease.RemainingMinutes -lt 15) { [ConsoleColor]::Red } else { [ConsoleColor]::Green }
        Write-Host "   - 剩余有效时间: $($dhcpLease.RemainingMinutes) 分钟 (约 $($dhcpLease.RemainingHours) 小时)" -ForegroundColor $remColor
        Write-Host "   - RFC 2131 机制说明: $($dhcpLease.LeaseStateNote)" -ForegroundColor Gray
    } else {
        Write-Host "   - DHCP 租约说明: $($dhcpLease.LeaseStateNote)" -ForegroundColor Gray
    }

    # 7. NCSI 系统网络连通性判定 (新增能力 5)
    Write-Host "`n[7/12] NCSI 系统连通性判定与探针状态 (只读):" -ForegroundColor Yellow
    $ncsi = Get-NcsiStatus
    $ncsiColor = if ($ncsi.IPv4Connectivity -eq 'Internet') { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
    Write-Host "   - Windows 任务栏连接判定: IPv4 -> $($ncsi.IPv4Connectivity), IPv6 -> $($ncsi.IPv6Connectivity)" -ForegroundColor $ncsiColor
    Write-Host "   - 网络位置类别 (Category): $($ncsi.NetworkCategory)"
    Write-Host "   - 网络位置感知服务 (NlaSvc): $($ncsi.NlaServiceStatus)"
    Write-Host "   - 注册表主动探测开关 (EnableActiveProbing): $($ncsi.EnableActiveProbing)"
    Write-Host "   - HTTP Web 探针地址: http://$($ncsi.ActiveWebProbeHost)/connecttest.txt"
    Write-Host "   - DNS 连通性探针域名: $($ncsi.ActiveDnsProbeHost)"
    Write-Host "   - 判定原理说明: $($ncsi.DiagnosisNote)" -ForegroundColor Gray

    # 8. 网关连通性 (ICMP Ping, 仅作参考)
    Write-Host "`n[8/12] 动态网关连通性 (参考信号):" -ForegroundColor Yellow
    $gwTest = Test-DynamicGateway -Gateway $routeInfo.NextHop
    if ($gwTest.PingOk) {
        Write-Host "   - 网关 ($($gwTest.Gateway)) ICMP 连通: 正常响应" -ForegroundColor Green
    } else {
        Write-Host "   - 网关 ($($gwTest.Gateway)) ICMP 连通: $($gwTest.Note)" -ForegroundColor Yellow
    }

    # 9. 公网直连 TCP 握手探测 (绕过代理直连)
    Write-Host "`n[9/12] 公网直连 TCP 握手 (绕过系统代理，4 个不同运营商/端口目标):" -ForegroundColor Yellow
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

    # 10. DNS 域名解析
    Write-Host "`n[10/12] 域名系统 (DNS) 解析测试:" -ForegroundColor Yellow
    $dnsProbe = Test-DnsResolution -Domain $cfg.DnsTestDomain
    if ($dnsProbe.Resolves) {
        Write-Host "   - 测试域名: $($dnsProbe.Domain) -> 解析为: $($dnsProbe.Addresses)" -ForegroundColor Green
    } else {
        Write-Host "   - 测试域名: $($dnsProbe.Domain) -> 解析失败: $($dnsProbe.Error)" -ForegroundColor Red
    }

    # 11. 代理配置只读检查
    Write-Host "`n[11/12] 系统代理配置 (WinINET / WinHTTP 只读):" -ForegroundColor Yellow
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

    # 12. Windows 核心网络服务状态 (新增能力 6)
    Write-Host "`n[12/12] Windows 核心网络服务状态 (含 NlaSvc / WinHttpAutoProxySvc):" -ForegroundColor Yellow
    $services = Get-NetworkServiceStatus -ServiceNames $cfg.CoreNetworkServices

    $serviceRoles = @{
        "Dhcp"                = "DHCP 客户端 (动态 IP 地址与网关/DNS 获取)"
        "Dnscache"            = "DNS 解析缓存服务 (域名解析性能与名称缓存)"
        "nsi"                 = "Network Store Interface (网络路由与接口状态通知)"
        "Wlansvc"             = "WLAN AutoConfig (Wi-Fi 探测、连接与认证状态机)"
        "NlaSvc"              = "Network Location Awareness (网络位置感知与 NCSI 连通性判定)"
        "WinHttpAutoProxySvc" = "WinHTTP 自动代理发现 (WPAD 协议与 PAC 脚本处理)"
    }

    foreach ($s in $services) {
        $sColor = if ($s.Status -eq 'Running') { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        $role = if ($serviceRoles.ContainsKey($s.Name)) { $serviceRoles[$s.Name] } else { $s.DisplayName }
        Write-Host ("   - 服务 {0,-20} | 状态: {1,-8} | 启动类型: {2,-10} | 职责: {3}" -f $s.Name, $s.Status, $s.StartType, $role) -ForegroundColor $sColor
    }

    Write-Host "`n=======================================================================" -ForegroundColor Cyan
    Write-Host "                      只读诊断完成                                     " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan
}

function Invoke-RunTimelineAnalysis {
    [CmdletBinding()]
    param(
        [int]$Hours = -1
    )

    Write-Host "=======================================================================" -ForegroundColor Cyan
    Write-Host "                正在执行断网时间线关联分析...                          " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan

    $fwd = @{}
    if ($PSBoundParameters.ContainsKey('Hours') -and $Hours -ge 0) {
        $fwd['HoursBack'] = $Hours
    }
    $timeline = Get-NetworkEventTimeline @fwd

    Write-Host "`n[时间线汇总统计]" -ForegroundColor Yellow
    Write-Host "   - 分析时间窗口: 最近 $($timeline.HoursBack) 小时 (起始时间: $($timeline.StartTime))"
    Write-Host "   - 捕获事件与动作总数: $($timeline.TotalRecords) 条"
    Write-Host "   - WLAN 断开事件次数 (ID 8003/11004等): $($timeline.DisconnectCount) 次"
    Write-Host "   - WLAN 重连/连接失败次数 (ID 8002等): $($timeline.ReconnectFailureCount) 次"
    Write-Host "   - 动态密钥交换超时次数 (ID 11006等): $($timeline.KeyExchangeTimeoutCount) 次"
    Write-Host "   - RSSI 异常值 (如 255) 出现次数: $($timeline.RssiAbnormalCount) 次"
    Write-Host "   - 看门狗动作执行次数: $($timeline.WatchdogActionCount) 次"
    if (@($timeline.WatchdogActions).Count -gt 0) {
        Write-Host "   - 执行过的看门狗动作列表: $(@($timeline.WatchdogActions | Select-Object -Unique) -join '; ')"
    }

    if ($timeline.OtherEventCounts.Keys.Count -gt 0) {
        Write-Host "`n[其他未分类事件 ID 频次统计]:" -ForegroundColor Yellow
        foreach ($k in ($timeline.OtherEventCounts.Keys | Sort-Object)) {
            Write-Host "   - 事件 [$k]: $($timeline.OtherEventCounts[$k]) 次"
        }
    }

    if (@($timeline.Warnings).Count -gt 0) {
        Write-Host "`n[执行提示与跳过说明]:" -ForegroundColor Gray
        foreach ($w in $timeline.Warnings) {
            Write-Host "   * $w" -ForegroundColor Gray
        }
    }

    # 完整时序表写入 logs\ 目录 (带时间戳)
    $logsDir = Join-Path $ToolRoot "logs"
    if (-not (Test-Path -LiteralPath $logsDir)) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    }
    $tsStr = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $logFile = Join-Path $logsDir "timeline_$tsStr.log"

    $logLines = [System.Collections.Generic.List[string]]::new()
    $logLines.Add("================================================================================")
    $logLines.Add("Windows 10/11 便携网络诊断工具箱 - 断网时间线关联分析报告")
    $logLines.Add("生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | 分析窗口: 最近 $($timeline.HoursBack) 小时")
    $logLines.Add("免责声明: $($timeline.Disclaimer)")
    $logLines.Add("================================================================================")
    $fmtHeader = "{0,-19} | {1,-8} | {2,-6} | {3,-11} | {4}" -f "时间戳", "来源", "事件ID", "级别", "事件摘要"
    $logLines.Add($fmtHeader)
    $logLines.Add("-" * 80)

    foreach ($r in $timeline.Records) {
        $eidStr = if ($r.EventId) { [string]$r.EventId } else { "-" }
        $lineText = "{0,-19} | {1,-8} | {2,-6} | {3,-11} | {4}" -f $r.TimeCreated, $r.Source, $eidStr, $r.Level, $r.Summary
        $logLines.Add($lineText)
    }

    [System.IO.File]::WriteAllLines($logFile, $logLines, [System.Text.Encoding]::UTF8)

    Write-Host "`n[完整时序表已落盘]" -ForegroundColor Green
    Write-Host "   - 完整记录文件: $logFile"

    # 控制台只显示汇总统计 + 最近 20 条
    Write-Host "`n[最近事件时序流 (控制台展示最近 20 条)]:" -ForegroundColor Yellow
    if ($timeline.TotalRecords -eq 0) {
        Write-Host "   该时间窗内无事件 (0 条记录)。" -ForegroundColor Gray
    } else {
        $recent20 = @($timeline.Records | Select-Object -Last 20)
        foreach ($r in $recent20) {
            $eidStr = if ($r.EventId) { "[ID: $($r.EventId)]" } else { "[Action]" }
            $srcColor = switch ($r.Source) {
                'WLAN'     { [ConsoleColor]::Magenta }
                'System'   { [ConsoleColor]::Cyan }
                'Watchdog' { [ConsoleColor]::Yellow }
                default    { [ConsoleColor]::White }
            }
            Write-Host -NoNewline "   $($r.TimeCreated) " -ForegroundColor Gray
            Write-Host -NoNewline "[$($r.Source)] " -ForegroundColor $srcColor
            Write-Host -NoNewline "$eidStr " -ForegroundColor White
            Write-Host "$($r.Summary)"
        }
    }

    # 免责说明 (原文照写)
    Write-Host "`n$($timeline.Disclaimer)" -ForegroundColor Cyan
}


try {
    switch ($Action) {
        'Timeline' {
            $fwd = @{}
            if ($PSBoundParameters.ContainsKey('HoursBack')) {
                $fwd['Hours'] = $HoursBack
            }
            Invoke-RunTimelineAnalysis @fwd
        }
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

        'SaveBaseline' {
            $fwd = @{}
            if ($PSBoundParameters.ContainsKey('WhatIf')) { $fwd['WhatIf'] = $WhatIfPreference }
            $res = Save-NetworkBaseline -ToolRoot $ToolRoot @fwd
            exit $res.ExitCode
        }

        'CompareBaseline' {
            $fwd = @{}
            if ($PSBoundParameters.ContainsKey('WhatIf')) { $fwd['WhatIf'] = $WhatIfPreference }
            if ($PSBoundParameters.ContainsKey('BaselineFile') -and -not [string]::IsNullOrWhiteSpace($BaselineFile)) {
                $fwd['BaselineFile'] = $BaselineFile
            }
            $res = Compare-NetworkBaseline -ToolRoot $ToolRoot @fwd
            exit $res.ExitCode
        }

        'Help' {
            Write-Host "便携网络诊断工具箱使用帮助:" -ForegroundColor Cyan
            Write-Host "  -Action FullHealth / Diagnose  : 执行纯只读网络健康诊断并输出控制台"
            Write-Host "  -Action Timeline [-HoursBack N]: 执行断网时间线关联分析 (默认 24 小时)"
            Write-Host "  -Action Bundle                 : 采集脱敏日志并打包为 output\*.zip"
            Write-Host "  -Action BackupDrivers          : 使用 PnPUtil 只读备份驱动至 backups\Drivers"
            Write-Host "  -Action SaveBaseline           : 保存当前网络健康与配置基线 (退出码: 0成功, 1错误)"
            Write-Host "  -Action CompareBaseline        : 与基线比对差异 (退出码: 0无差异, 2有差异, 1错误)"
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

                Write-Host "   [1] Execute Read-Only Network Diagnostics (执行纯只读网络健康与配置诊断)" -ForegroundColor White
                Write-Host "   [2] Generate Diagnostic Log Bundle (ZIP) (生成诊断报告与脱敏压缩包)" -ForegroundColor White
                Write-Host "   [3] Export Third-Party Network Driver Catalog (导出第三方网络驱动清单与包)" -ForegroundColor White
                Write-Host "   [4] Analyze Disconnection Timeline (断网时间线关联分析)" -ForegroundColor White
                Write-Host "   [5] Save Health Baseline (保存当前健康基线)" -ForegroundColor White
                Write-Host "   [6] Compare With Baseline (与基线比对差异)" -ForegroundColor White
                Write-Host "   [0] Exit (退出工具箱)" -ForegroundColor Gray
                Write-Host "=======================================================================" -ForegroundColor Cyan
                Write-Host "请输入选项数字 [0-6]: " -ForegroundColor Yellow -NoNewline
                $choice = Read-Host

                switch ($choice.Trim()) {
                    '4' {
                        Write-Host "Enter hours to look back (default from config, e.g. 24): " -ForegroundColor Yellow -NoNewline
                        $hInput = Read-Host
                        $hVal = 0
                        if ($hInput.Trim() -match '^\d+$') {
                            $hVal = [int]$hInput.Trim()
                        }
                        Invoke-RunTimelineAnalysis -Hours $hVal
                        Write-Host "`n按回车键返回菜单..."; Read-Host | Out-Null
                    }
                    '5' {
                        Save-NetworkBaseline -ToolRoot $ToolRoot
                        Write-Host "`n按回车键返回菜单..."; Read-Host | Out-Null
                    }
                    '6' {
                        Write-Host "Enter baseline file name (or leave empty to compare with latest): " -ForegroundColor Yellow -NoNewline
                        $bInput = Read-Host
                        $bFwd = @{}
                        if (-not [string]::IsNullOrWhiteSpace($bInput)) {
                            $bFwd['BaselineFile'] = $bInput.Trim()
                        }
                        Compare-NetworkBaseline -ToolRoot $ToolRoot @bFwd
                        Write-Host "`n按回车键返回菜单..."; Read-Host | Out-Null
                    }
                    '1' { Invoke-RunDiagnosis; Write-Host "`n按回车键返回菜单..."; Read-Host | Out-Null }
                    '2' {
                        Write-Host "Include WLAN profiles? (Y/N, default N): " -ForegroundColor Yellow -NoNewline
                        $wlanChoice = Read-Host
                        $incWlan = ($wlanChoice.Trim() -eq 'y' -or $wlanChoice.Trim() -eq 'Y')
                        New-DiagnosticBundle -ToolRoot $ToolRoot -IncludeWlanReport:$incWlan
                        Write-Host "`n按回车键返回菜单..."; Read-Host | Out-Null
                    }
                    '3' {
                        if (-not (Test-IsAdmin)) {
                            Write-Host "Driver catalog export requires Administrator privileges." -ForegroundColor Yellow
                            Write-Host "Relaunching with elevation..." -ForegroundColor Yellow
                            Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action ExportDrivers" -Verb RunAs -Wait
                        } else {
                            Export-NetworkDrivers -ToolRoot $ToolRoot
                        }
                        Write-Host "`n按回车键返回菜单..."; Read-Host | Out-Null
                    }
                    '0' {
                        Write-Host "Exiting." -ForegroundColor Yellow
                        break
                    }
                    default {
                        Write-Host "Invalid choice. Press Enter to retry." -ForegroundColor Red
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

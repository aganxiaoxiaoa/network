# ==============================================================================
# NetworkInventory.psm1
# 便携网络只读诊断工具箱 - 网络清单与静态环境检测模块
# 严格遵循只读原则：不改变任何系统配置、不修改注册表、不重启服务、不修改网卡
# ==============================================================================

Set-StrictMode -Version 2.0

function Get-ToolConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot "..\NetworkRecovery.Config.psd1")
    )
    if (Test-Path $ConfigPath) {
        try {
            Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
            if (Get-Command -Name Import-PowerShellDataFile -ErrorAction SilentlyContinue) {
                return (Import-PowerShellDataFile -Path $ConfigPath)
            }
        } catch { }
    }
    return @{
        PublicWanTargets = @("223.5.5.5:53", "119.29.29.29:53", "114.114.114.114:53", "www.baidu.com:443")
        TcpProbeTimeoutMs = 5000
        DnsTestDomain = "www.microsoft.com"
        CoreNetworkServices = @("Dhcp", "Dnscache", "nsi", "Wlansvc", "NlaSvc", "WinHttpAutoProxySvc")
        MinFreeSpaceMBForDrivers = 500
    }
}

function Get-DefaultRouteInfo {
    [CmdletBinding()]
    param()

    try {
        $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction Stop |
                    Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric })

        if (@($routes).Count -eq 0) {
            return [PSCustomObject]@{
                HasDefaultRoute = $false
                InterfaceIndex  = $null
                InterfaceAlias  = $null
                NextHop         = $null
                RouteMetric     = $null
                InterfaceMetric = $null
                EffectiveMetric = $null
            }
        }

        $best = $routes[0]
        return [PSCustomObject]@{
            HasDefaultRoute = $true
            InterfaceIndex  = $best.InterfaceIndex
            InterfaceAlias  = $best.InterfaceAlias
            NextHop         = $best.NextHop
            RouteMetric     = [int]$best.RouteMetric
            InterfaceMetric = [int]$best.InterfaceMetric
            EffectiveMetric = ([int]$best.RouteMetric + [int]$best.InterfaceMetric)
        }
    } catch {
        return [PSCustomObject]@{
            HasDefaultRoute = $false
            InterfaceIndex  = $null
            InterfaceAlias  = $null
            NextHop         = $null
            RouteMetric     = $null
            InterfaceMetric = $null
            EffectiveMetric = $null
            Error           = $_.Exception.Message
        }
    }
}

function Get-ActivePhysicalAdapter {
    [CmdletBinding()]
    param(
        [int]$PreferredInterfaceIndex = 0
    )

    $virtualRegex = 'TAP|TUN|Wintun|WireGuard|VPN|Hyper-V|vEthernet|WSL|Loopback|VirtualBox|VMware|AnyConnect'

    try {
        if ($PreferredInterfaceIndex -gt 0) {
            $nic = Get-NetAdapter -InterfaceIndex $PreferredInterfaceIndex -ErrorAction SilentlyContinue
            if ($nic -and $nic.HardwareInterface -and ($nic.InterfaceDescription -notmatch $virtualRegex)) {
                return [PSCustomObject]@{
                    Found                = $true
                    Name                 = $nic.Name
                    InterfaceAlias       = $nic.InterfaceAlias
                    InterfaceIndex       = $nic.InterfaceIndex
                    InterfaceGuid        = $nic.InterfaceGuid
                    InterfaceDescription = $nic.InterfaceDescription
                    Status               = $nic.Status
                    HardwareInterface    = $nic.HardwareInterface
                    MacAddress           = $nic.MacAddress
                    LinkSpeed            = $nic.LinkSpeed
                    IsDefaultRouteOwner  = $true
                }
            }
        }

        $upPhysical = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                      Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch $virtualRegex } |
                      Select-Object -First 1

        if ($upPhysical) {
            return [PSCustomObject]@{
                Found                = $true
                Name                 = $upPhysical.Name
                InterfaceAlias       = $upPhysical.InterfaceAlias
                InterfaceIndex       = $upPhysical.InterfaceIndex
                InterfaceGuid        = $upPhysical.InterfaceGuid
                InterfaceDescription = $upPhysical.InterfaceDescription
                Status               = $upPhysical.Status
                HardwareInterface    = $upPhysical.HardwareInterface
                MacAddress           = $upPhysical.MacAddress
                LinkSpeed            = $upPhysical.LinkSpeed
                IsDefaultRouteOwner  = ($upPhysical.InterfaceIndex -eq $PreferredInterfaceIndex)
            }
        }

        $anyPhysical = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                       Where-Object { $_.InterfaceDescription -notmatch $virtualRegex } |
                       Select-Object -First 1

        if ($anyPhysical) {
            return [PSCustomObject]@{
                Found                = $true
                Name                 = $anyPhysical.Name
                InterfaceAlias       = $anyPhysical.InterfaceAlias
                InterfaceIndex       = $anyPhysical.InterfaceIndex
                InterfaceGuid        = $anyPhysical.InterfaceGuid
                InterfaceDescription = $anyPhysical.InterfaceDescription
                Status               = $anyPhysical.Status
                HardwareInterface    = $anyPhysical.HardwareInterface
                MacAddress           = $anyPhysical.MacAddress
                LinkSpeed            = $anyPhysical.LinkSpeed
                IsDefaultRouteOwner  = $false
            }
        }

        return [PSCustomObject]@{
            Found = $false
            Name  = $null
            Error = "未找到可用的物理网络适配器"
        }
    } catch {
        return [PSCustomObject]@{
            Found = $false
            Name  = $null
            Error = $_.Exception.Message
        }
    }
}

function Get-AdapterIpDetails {
    [CmdletBinding()]
    param(
        [int]$InterfaceIndex
    )

    if ($InterfaceIndex -le 0) {
        return [PSCustomObject]@{
            IPv4Address = $null
            IsApipa     = $false
            DhcpEnabled = $false
            DnsServers  = @()
        }
    }

    try {
        $ipInfo = Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.IPAddress -notlike "127.*" } |
                  Select-Object -First 1

        $ipAddr = if ($ipInfo) { $ipInfo.IPAddress } else { $null }
        $isApipa = if ($ipAddr) { $ipAddr -like "169.254.*" } else { $false }

        $ipIntf = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dhcpEnabled = if ($ipIntf) { ($ipIntf.Dhcp -eq 'Enabled') } else { $false }

        $dnsInfo = Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dnsServers = if ($dnsInfo -and $dnsInfo.PSObject.Properties['ServerAddresses'] -and $dnsInfo.ServerAddresses) { @($dnsInfo.ServerAddresses) } else { @() }

        return [PSCustomObject]@{
            IPv4Address = $ipAddr
            IsApipa     = $isApipa
            DhcpEnabled = $dhcpEnabled
            DnsServers  = $dnsServers
        }
    } catch {
        return [PSCustomObject]@{
            IPv4Address = $null
            IsApipa     = $false
            DhcpEnabled = $false
            DnsServers  = @()
            Error       = $_.Exception.Message
        }
    }
}

function Get-ProxyStatus {
    [CmdletBinding()]
    param()

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $winInet = $null
    if (Test-Path $regPath) {
        $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        $winInet = [PSCustomObject]@{
            ProxyEnable   = if ($props -and $props.PSObject.Properties['ProxyEnable']) { [int]$props.ProxyEnable } else { 0 }
            ProxyServer   = if ($props -and $props.PSObject.Properties['ProxyServer']) { [string]$props.ProxyServer } else { $null }
            ProxyOverride = if ($props -and $props.PSObject.Properties['ProxyOverride']) { [string]$props.ProxyOverride } else { $null }
            AutoConfigURL = if ($props -and $props.PSObject.Properties['AutoConfigURL']) { [string]$props.AutoConfigURL } else { $null }
            AutoDetect    = if ($props -and $props.PSObject.Properties['AutoDetect']) { [int]$props.AutoDetect } else { $null }
        }
    }

    $winHttpRaw = ""
    try {
        $winHttpRaw = (netsh winhttp show proxy 2>&1) -join "`n"
    } catch {
        $winHttpRaw = "无法获取 WinHTTP 配置: $($_.Exception.Message)"
    }

    return [PSCustomObject]@{
        WinInet = $winInet
        WinHttp = $winHttpRaw.Trim()
    }
}

function Get-NetworkServiceStatus {
    [CmdletBinding()]
    param(
        [string[]]$ServiceNames = @("Dhcp", "Dnscache", "nsi", "Wlansvc")
    )

    $results = @()
    foreach ($svcName in $ServiceNames) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc) {
                $results += [PSCustomObject]@{
                    Name        = $svc.Name
                    DisplayName = $svc.DisplayName
                    Status      = $svc.Status.ToString()
                    StartType   = $svc.StartType.ToString()
                }
            } else {
                $results += [PSCustomObject]@{
                    Name        = $svcName
                    DisplayName = "未安装或不可见"
                    Status      = "NotFound"
                    StartType   = "Unknown"
                }
            }
        } catch {
            $results += [PSCustomObject]@{
                Name        = $svcName
                DisplayName = "获取异常"
                Status      = "Error"
                StartType   = $_.Exception.Message
            }
        }
    }
    return $results
}

function Get-WlanDiagnostics {
    [CmdletBinding()]
    param()

    $interfaces = ""
    $drivers = ""
    try {
        $interfaces = (netsh wlan show interfaces 2>&1) -join "`n"
    } catch {
        $interfaces = "获取 WLAN 接口信息失败: $($_.Exception.Message)"
    }

    try {
        $drivers = (netsh wlan show drivers 2>&1) -join "`n"
    } catch {
        $drivers = "获取 WLAN 驱动信息失败: $($_.Exception.Message)"
    }

    return [PSCustomObject]@{
        Interfaces = $interfaces.Trim()
        Drivers    = $drivers.Trim()
    }
}

function Get-LocalWatchdogStatus {
    [CmdletBinding()]
    param()

    $task = Get-ScheduledTask -TaskName "NetworkRecoveryWatchdog" -ErrorAction SilentlyContinue
    $taskState = if ($task) { $task.State.ToString() } else { "NotInstalled" }

    $watchdogProc = Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -match "auto_network_recovery\.ps1"
    } | Select-Object -First 1

    $procRunning = ($null -ne $watchdogProc)
    $procId = if ($watchdogProc) { $watchdogProc.ProcessId } else { $null }

    # 检查 Clash/ProxyStack 状态 (修复 Bug 1: 当零进程时使用 @() 包装，避免 StrictMode 2.0 下访问 $null.Count 抛错)
    $proxyProcs = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match "clash-verge|verge-mihomo|ProxyBridge"
    }

    return [PSCustomObject]@{
        TaskExists      = ($null -ne $task)
        TaskState       = $taskState
        ProcRunning     = $procRunning
        ProcessId       = $procId
        ProxyStackCount = @($proxyProcs).Count
        IsProtected     = ($taskState -eq 'Running' -or $procRunning)
    }
}

function Get-IPv6Status {
    [CmdletBinding()]
    param(
        [int]$PreferredInterfaceIndex = 0
    )

    try {
        $routes = @(Get-NetRoute -DestinationPrefix '::/0' -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                    Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric })

        $hasDefaultRoute = (@($routes).Count -gt 0)
        $bestRoute = if ($hasDefaultRoute) { $routes[0] } else { $null }

        $ifIndex = if ($bestRoute) { [int]$bestRoute.InterfaceIndex } elseif ($PreferredInterfaceIndex -gt 0) { $PreferredInterfaceIndex } else { 0 }

        $intfInfo = if ($ifIndex -gt 0) {
            Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue
        } else { $null }

        $ipAddrs = if ($ifIndex -gt 0) {
            @(Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue)
        } else { @() }

        $globalAddrs = @($ipAddrs | Where-Object { $_.IPAddress -notlike "fe80*" -and $_.IPAddress -ne "::1" } | Select-Object -ExpandProperty IPAddress)
        $linkLocalAddrs = @($ipAddrs | Where-Object { $_.IPAddress -like "fe80*" } | Select-Object -ExpandProperty IPAddress)

        $nextHop = if ($bestRoute) { $bestRoute.NextHop } else { $null }
        $effMetric = if ($bestRoute) { [int]$bestRoute.RouteMetric + [int]$bestRoute.InterfaceMetric } else { $null }

        return [PSCustomObject]@{
            HasDefaultRoute    = $hasDefaultRoute
            InterfaceIndex     = $ifIndex
            InterfaceAlias     = if ($bestRoute) { $bestRoute.InterfaceAlias } elseif ($intfInfo) { $intfInfo.InterfaceAlias } else { $null }
            NextHop            = $nextHop
            RouteMetric        = if ($bestRoute) { [int]$bestRoute.RouteMetric } else { $null }
            InterfaceMetric    = if ($bestRoute) { [int]$bestRoute.InterfaceMetric } else { $null }
            EffectiveMetric    = $effMetric
            DhcpEnabled        = if ($intfInfo) { ($intfInfo.Dhcp -eq 'Enabled') } else { $false }
            ConnectionState    = if ($intfInfo) { $intfInfo.ConnectionState.ToString() } else { "Unknown" }
            GlobalAddresses    = $globalAddrs
            LinkLocalAddresses = $linkLocalAddrs
        }
    } catch {
        return [PSCustomObject]@{
            HasDefaultRoute    = $false
            InterfaceIndex     = $null
            InterfaceAlias     = $null
            NextHop            = $null
            RouteMetric        = $null
            InterfaceMetric    = $null
            EffectiveMetric    = $null
            DhcpEnabled        = $false
            ConnectionState    = "Error"
            GlobalAddresses    = @()
            LinkLocalAddresses = @()
            Error              = $_.Exception.Message
        }
    }
}

function Get-AdapterPowerManagementStatus {
    [CmdletBinding()]
    param(
        [string]$AdapterName
    )

    if ([string]::IsNullOrWhiteSpace($AdapterName)) {
        return [PSCustomObject]@{
            Supported          = $false
            AllowTurnOffDevice = "Unknown"
            PowerSavingEnabled = $false
            DeviceSleepOnDisconnect = "Unknown"
            SelectiveSuspend   = "Unknown"
            Note               = "未指定适配器名称"
        }
    }

    try {
        $pm = Get-NetAdapterPowerManagement -Name $AdapterName -ErrorAction SilentlyContinue
        if ($pm) {
            $allowTurnOff = [string]$pm.AllowComputerToTurnOffDevice
            $isSaving = ($allowTurnOff -eq 'Enabled')
            $note = if ($isSaving) {
                "[提示] 检测到省电选项已开启 (允许计算机关闭此设备以节约电源)。根据微软官方与 Intel 排障指南，该设置可能导致系统空闲或睡眠唤醒时 Wi-Fi 异常断流掉线。本工具为纯只读模式，绝不自动修改此设置；如需关闭请手动在设备管理器网卡属性中调整。"
            } elseif ($allowTurnOff -eq 'Disabled') {
                "省电设置已关闭 (设备始终保持全功耗工作)"
            } elseif ($allowTurnOff -eq 'Unsupported') {
                "该硬件驱动不支持由操作系统接管电源睡眠控制 (Unsupported)"
            } else {
                "当前电源状态: $allowTurnOff"
            }

            return [PSCustomObject]@{
                Supported          = ($allowTurnOff -ne 'Unsupported')
                AllowTurnOffDevice = $allowTurnOff
                PowerSavingEnabled = $isSaving
                DeviceSleepOnDisconnect = [string]$pm.DeviceSleepOnDisconnect
                SelectiveSuspend   = [string]$pm.SelectiveSuspend
                Note               = $note
            }
        }

        return [PSCustomObject]@{
            Supported          = $false
            AllowTurnOffDevice = "NotAvailable"
            PowerSavingEnabled = $false
            DeviceSleepOnDisconnect = "Unknown"
            SelectiveSuspend   = "Unknown"
            Note               = "未获取到该网卡的电源管理属性"
        }
    } catch {
        return [PSCustomObject]@{
            Supported          = $false
            AllowTurnOffDevice = "Error"
            PowerSavingEnabled = $false
            DeviceSleepOnDisconnect = "Unknown"
            SelectiveSuspend   = "Unknown"
            Note               = "读取电源管理设置异常: $($_.Exception.Message)"
        }
    }
}

function Get-WlanLinkQuality {
    [CmdletBinding()]
    param()

    $raw = ""
    try {
        $raw = (netsh wlan show interfaces 2>&1) -join "`n"
    } catch {
        $raw = "执行异常: $($_.Exception.Message)"
    }

    if ($raw -match "Error 5|Access is denied|location permission|位置") {
        return [PSCustomObject]@{
            Available      = $false
            State          = "AccessDenied"
            SSID           = $null
            BSSID          = $null
            RadioType      = $null
            Band           = $null
            Channel        = $null
            ReceiveRate    = $null
            TransmitRate   = $null
            SignalPercent  = $null
            RssiEstimated  = $null
            Note           = "Windows 11 隐私与位置限制：查询无线链路质量详情需要开启系统‘位置’权限或以管理员身份运行。底层 WlanQueryInterface 返回拒绝访问 (Error 5)。"
        }
    }

    $state = if ($raw -match '(?i)^\s*(?:State|状态)\s*:\s*(.+)$') { $matches[1].Trim() } else { "Unknown" }
    $rawSsid = if ($raw -match '(?i)^\s*(?:SSID)\s*:\s*(.+)$') { $matches[1].Trim() } else { $null }
    $rawBssid = if ($raw -match '(?i)^\s*(?:BSSID)\s*:\s*(.+)$') { $matches[1].Trim() } else { $null }
    $radioType = if ($raw -match '(?i)^\s*(?:Radio type|无线电类型)\s*:\s*(.+)$') { $matches[1].Trim() } else { $null }
    $rawBand = if ($raw -match '(?i)^\s*(?:Band|频段)\s*:\s*(.+)$') { $matches[1].Trim() } else { $null }
    $channel = if ($raw -match '(?i)^\s*(?:Channel|信道)\s*:\s*(\d+)') { [int]$matches[1] } else { $null }
    $rxRate = if ($raw -match '(?i)^\s*(?:Receive rate \(Mbps\)|接收速率\s*\(Mbps\))\s*:\s*(\d+)') { [int]$matches[1] } else { $null }
    $txRate = if ($raw -match '(?i)^\s*(?:Transmit rate \(Mbps\)|传输速率\s*\(Mbps\))\s*:\s*(\d+)') { [int]$matches[1] } else { $null }
    $signal = if ($raw -match '(?i)^\s*(?:Signal|信号)\s*:\s*(\d+)%') { [int]$matches[1] } else { $null }

    # 推断频段 (若输出中无显式 Band 字段)
    $band = $rawBand
    if (-not $band -and $channel) {
        if ($channel -ge 1 -and $channel -le 14) {
            $band = "2.4 GHz"
        } elseif ($channel -ge 36 -and $channel -le 165) {
            $band = "5 GHz"
        } elseif ($channel -ge 1 -and $channel -le 233 -and $radioType -match '6E|ax') {
            $band = "5 GHz / 6 GHz"
        }
    }

    # 脱敏 SSID
    $safeSsid = if ($rawSsid) {
        if ($rawSsid.Length -le 2) { "**" } else { "$($rawSsid[0])****$($rawSsid[$rawSsid.Length - 1])" }
    } else { "[未关联 SSID]" }

    # 脱敏 BSSID
    $safeBssid = if ($rawBssid) {
        $parts = $rawBssid -split '[:-]'
        if (@($parts).Count -eq 6) {
            "$($parts[0]):$($parts[1]):$($parts[2]):**:**:**"
        } else {
            "**:**:**:**:**:**"
        }
    } else { "[未关联 BSSID]" }

    # 根据 Windows 信号百分比换算估算 RSSI (Signal% = 2 * (dBm + 100))
    $rssiEst = if ($signal) {
        [math]::Round(($signal / 2) - 100, 0)
    } else { $null }

    $note = ""
    if ($signal) {
        if ($signal -lt 50) {
            $note = "[警告] 信号强度低于 50% (估算 RSSI: $rssiEst dBm)。弱信号或信道拥堵极易导致 802.11 密钥重协商 (4-Way Handshake) 超时，引发意外断开。"
        } else {
            $note = "无线信号质量良好 (估算 RSSI: $rssiEst dBm)。"
        }
    } else {
        $note = "未检测到活跃的 Wi-Fi 信号强度。"
    }

    return [PSCustomObject]@{
        Available     = ($state -match "connected|已连接")
        State         = $state
        SSID          = $safeSsid
        BSSID         = $safeBssid
        RadioType     = $radioType
        Band          = $band
        Channel       = $channel
        ReceiveRate   = $rxRate
        TransmitRate  = $txRate
        SignalPercent = $signal
        RssiEstimated = $rssiEst
        Note          = $note
    }
}

function Get-DhcpLeaseInfo {
    [CmdletBinding()]
    param()

    try {
        $dhcpAdapters = @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
                          Where-Object { $_.IPEnabled -and $_.DHCPEnabled })

        if (@($dhcpAdapters).Count -eq 0) {
            return [PSCustomObject]@{
                DhcpActive        = $false
                DHCPServer        = $null
                LeaseObtained     = $null
                LeaseExpires      = $null
                RemainingMinutes  = $null
                RemainingHours    = $null
                LeaseStateNote    = "当前活动网络适配器未通过 DHCP 动态分配 (可能使用静态 IP 或受控虚拟接口)"
            }
        }

        $cfg = $dhcpAdapters[0]
        $dhcpServer = $cfg.DHCPServer
        $leaseObt = $cfg.DHCPLeaseObtained
        $leaseExp = $cfg.DHCPLeaseExpires

        $now = Get-Date
        $remMin = $null
        $remHour = $null
        $note = ""

        if ($leaseExp) {
            $expDate = [datetime]$leaseExp
            $diff = $expDate - $now
            $remMin = [math]::Round($diff.TotalMinutes, 1)
            $remHour = [math]::Round($diff.TotalHours, 1)

            if ($remMin -le 0) {
                $note = "[严重警告] DHCP 租约已过期！系统可能已丢失有效 IP 配置或处于网络脱机状态。根据 RFC 2131，租约过期后系统必须重新进入 INIT 状态发起 DHCPDISCOVER。"
            } elseif ($remMin -lt 15) {
                $note = "[警告] DHCP 租约即将在 $remMin 分钟内到期 (已达 T2 重绑定超时阶段，客户端正尝试广播寻找可用 DHCP 服务器)。本工具严格保持只读，绝不执行续租。"
            } else {
                $note = "DHCP 租约正常有效 (剩余约 $remHour 小时)。RFC 2131 标准下，客户端通常在租约度过 50% (T1) 时向原 DHCP 服务器发起单播续租请求。"
            }
        } else {
            $note = "未获取到有效的 DHCP 到期时间。"
        }

        return [PSCustomObject]@{
            DhcpActive        = $true
            DHCPServer        = $dhcpServer
            LeaseObtained     = if ($leaseObt) { ([datetime]$leaseObt).ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
            LeaseExpires      = if ($leaseExp) { ([datetime]$leaseExp).ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
            RemainingMinutes  = $remMin
            RemainingHours    = $remHour
            LeaseStateNote    = $note
        }
    } catch {
        return [PSCustomObject]@{
            DhcpActive        = $false
            DHCPServer        = $null
            LeaseObtained     = $null
            LeaseExpires      = $null
            RemainingMinutes  = $null
            RemainingHours    = $null
            LeaseStateNote    = "获取 DHCP 租约异常: $($_.Exception.Message)"
        }
    }
}

function Get-NcsiStatus {
    [CmdletBinding()]
    param()

    try {
        $profile = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue) | Select-Object -First 1
        $ipv4Conn = if ($profile) { $profile.IPv4Connectivity.ToString() } else { "Unknown" }
        $ipv6Conn = if ($profile) { $profile.IPv6Connectivity.ToString() } else { "Unknown" }
        $netCategory = if ($profile) { $profile.NetworkCategory.ToString() } else { "Unknown" }

        # 读取 NCSI 注册表探针配置 (纯只读查询，严禁修改)
        $ncsiRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet"
        $activeProbing = $null
        $webHost = $null
        $dnsHost = $null
        if (Test-Path $ncsiRegPath) {
            $regProps = Get-ItemProperty -Path $ncsiRegPath -ErrorAction SilentlyContinue
            if ($regProps) {
                if ($regProps.PSObject.Properties['EnableActiveProbing']) { $activeProbing = [int]$regProps.EnableActiveProbing }
                if ($regProps.PSObject.Properties['ActiveWebProbeHost']) { $webHost = [string]$regProps.ActiveWebProbeHost }
                if ($regProps.PSObject.Properties['ActiveDnsProbeHost']) { $dnsHost = [string]$regProps.ActiveDnsProbeHost }
            }
        }

        # 读取 NlaSvc 服务状态
        $nlaSvc = Get-Service -Name "NlaSvc" -ErrorAction SilentlyContinue
        $nlaStatus = if ($nlaSvc) { $nlaSvc.Status.ToString() } else { "NotFound" }

        $diagnosisNote = if ($ipv4Conn -eq 'Internet') {
            "Windows 判定当前具备完整的 Internet 连通性 (任务栏网络图标正常)。"
        } elseif ($ipv4Conn -eq 'LocalNetwork') {
            "[提示] Windows 判定当前仅具备本地局域网连通性 (无 Internet 访问)。若此时浏览器等应用可正常上网，说明 NCSI 主动探测请求被代理/防火墙阻断，或 NlaSvc 未运行，导致系统判定偏差。"
        } else {
            "[警告] Windows 判定当前处于无流量或脱机断网状态 (IPv4: $ipv4Conn, IPv6: $ipv6Conn)。"
        }

        return [PSCustomObject]@{
            IPv4Connectivity    = $ipv4Conn
            IPv6Connectivity    = $ipv6Conn
            NetworkCategory     = $netCategory
            NlaServiceStatus    = $nlaStatus
            EnableActiveProbing = $activeProbing
            ActiveWebProbeHost  = $webHost
            ActiveDnsProbeHost  = $dnsHost
            DiagnosisNote       = $diagnosisNote
        }
    } catch {
        return [PSCustomObject]@{
            IPv4Connectivity    = "Error"
            IPv6Connectivity    = "Error"
            NetworkCategory     = "Error"
            NlaServiceStatus    = "Error"
            EnableActiveProbing = $null
            ActiveWebProbeHost  = $null
            ActiveDnsProbeHost  = $null
            DiagnosisNote       = "获取 NCSI 状态异常: $($_.Exception.Message)"
        }
    }
}

Export-ModuleMember -Function @(
    'Get-ToolConfig',
    'Get-DefaultRouteInfo',
    'Get-IPv6Status',
    'Get-ActivePhysicalAdapter',
    'Get-AdapterPowerManagementStatus',
    'Get-WlanLinkQuality',
    'Get-AdapterIpDetails',
    'Get-DhcpLeaseInfo',
    'Get-NcsiStatus',
    'Get-ProxyStatus',
    'Get-NetworkServiceStatus',
    'Get-WlanDiagnostics',
    'Get-LocalWatchdogStatus'
)

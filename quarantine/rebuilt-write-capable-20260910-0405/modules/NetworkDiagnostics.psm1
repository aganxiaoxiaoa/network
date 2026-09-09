# ==============================================================================
# NetworkDiagnostics.psm1
# Windows 10/11 便携网络诊断与恢复工具箱 - 纯只读诊断与环境探测模块
# 绝对安全原则：纯只读，零网络状态变更，零破坏性调用
# ==============================================================================

Set-StrictMode -Version 2.0

function Test-LocalWatchdogConflict {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        LocalWatchdogFound   = $false
        ScheduledTaskRunning = $false
        TaskName             = "NetworkRecoveryWatchdog"
        Details              = "未检测到本地宿主机看门狗冲突。"
    }

    try {
        $task = Get-ScheduledTask -TaskName 'NetworkRecoveryWatchdog' -ErrorAction SilentlyContinue
        if ($task) {
            $result.LocalWatchdogFound = $true
            if ($task.State -eq 'Running') {
                $result.ScheduledTaskRunning = $true
                $result.Details = "本地计划任务 'NetworkRecoveryWatchdog' 正在运行中 (状态: $($task.State))。本 U 盘工具与之完全独立互斥，绝不修改、停止或重新配置该本地看门狗。"
            } else {
                $result.Details = "本地存在计划任务 'NetworkRecoveryWatchdog' (状态: $($task.State))。本工具与其完全互斥隔离。"
            }
        }
    } catch {
        # 兼容权限受限场景
    }
    return $result
}

function Get-DefaultIPv4RouteAndGateway {
    [CmdletBinding()]
    param()

    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric })

    if (@($routes).Count -eq 0) {
        return [PSCustomObject]@{
            Found           = $false
            NextHop         = $null
            InterfaceIndex  = $null
            InterfaceAlias  = $null
            RouteMetric     = $null
            InterfaceMetric = $null
            EffectiveMetric = $null
        }
    }

    $best = $routes[0]
    return [PSCustomObject]@{
        Found           = $true
        NextHop         = $best.NextHop
        InterfaceIndex  = [int]$best.InterfaceIndex
        InterfaceAlias  = $best.InterfaceAlias
        RouteMetric     = [int]$best.RouteMetric
        InterfaceMetric = [int]$best.InterfaceMetric
        EffectiveMetric = [int]$best.RouteMetric + [int]$best.InterfaceMetric
    }
}

function Get-ActivePhysicalAdapter {
    [CmdletBinding()]
    param(
        [int]$PreferredInterfaceIndex = 0
    )

    $allAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $physicalAdapters = @($allAdapters | Where-Object {
        $_.HardwareInterface -eq $true -and
        $_.InterfaceDescription -notmatch 'Virtual|VPN|TAP|TUN|Wintun|WireGuard|Hyper-V|vEthernet|WSL|Loopback|Bluetooth' -and
        $_.Name -notmatch 'vEthernet|Loopback|Bluetooth'
    })

    if ($PreferredInterfaceIndex -gt 0) {
        $matched = $physicalAdapters | Where-Object { $_.InterfaceIndex -eq $PreferredInterfaceIndex } | Select-Object -First 1
        if ($matched) {
            return [PSCustomObject]@{
                Found                = $true
                Name                 = $matched.Name
                InterfaceAlias       = $matched.InterfaceAlias
                InterfaceIndex       = $matched.InterfaceIndex
                InterfaceGuid        = $matched.InterfaceGuid
                InterfaceDescription = $matched.InterfaceDescription
                Status               = $matched.Status
                HardwareInterface    = $matched.HardwareInterface
                MacAddress           = $matched.MacAddress
                LinkSpeed            = $matched.LinkSpeed
                IsUp                 = ($matched.Status -eq 'Up')
            }
        }
    }

    $upPhysical = $physicalAdapters | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
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
            IsUp                 = $true
        }
    }

    $anyPhysical = $physicalAdapters | Select-Object -First 1
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
            IsUp                 = ($anyPhysical.Status -eq 'Up')
        }
    }

    return [PSCustomObject]@{
        Found                = $false
        Name                 = $null
        InterfaceAlias       = $null
        InterfaceIndex       = $null
        InterfaceGuid        = $null
        InterfaceDescription = $null
        Status               = "Not Found"
        HardwareInterface    = $false
        MacAddress           = $null
        LinkSpeed            = $null
        IsUp                 = $false
    }
}

function Get-IPv6Status {
    [CmdletBinding()]
    param()

    $v6Routes = @(Get-NetRoute -DestinationPrefix '::/0' -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                  Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric })

    $hasDefaultV6Route = (@($v6Routes).Count -gt 0)
    $v6Gateway = if ($hasDefaultV6Route) { $v6Routes[0].NextHop } else { $null }
    $v6IfIndex = if ($hasDefaultV6Route) { [int]$v6Routes[0].InterfaceIndex } else { $null }

    $globalV6Addrs = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                       Where-Object { $_.IPAddress -notmatch '^fe80' -and $_.IPAddress -notmatch '^::1' })

    $hasGlobalV6 = (@($globalV6Addrs).Count -gt 0)
    $stateDesc = if ($hasDefaultV6Route -and $hasGlobalV6) {
        "已配置 IPv6 默认路由及全球单播地址 (双栈环境)"
    } elseif ($hasDefaultV6Route -and -not $hasGlobalV6) {
        "存在 IPv6 默认路由但无有效全球单播地址 (潜在 IPv6 路由黑洞，可能引发首包解析超时)"
    } else {
        "未配置全局 IPv6 默认路由 (纯 IPv4 正常运行模式)"
    }

    return [PSCustomObject]@{
        HasDefaultRoute = $hasDefaultV6Route
        Gateway         = $v6Gateway
        InterfaceIndex  = $v6IfIndex
        HasGlobalV6     = $hasGlobalV6
        GlobalAddresses = @($globalV6Addrs | Select-Object -ExpandProperty IPAddress)
        StateDescription = $stateDesc
    }
}

function Get-AdapterPowerManagementStatus {
    [CmdletBinding()]
    param(
        [string]$InterfaceDescription = ""
    )

    $result = [PSCustomObject]@{
        Supported                   = $false
        AllowComputerToTurnOffDevice = $null
        Warning                     = "未检测到节能风险"
        Guidance                    = "节能管理状态正常"
    }

    try {
        $pnpDevs = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.PNPClass -eq 'Net' })
        $matchedDev = if (-not [string]::IsNullOrEmpty($InterfaceDescription)) {
            $pnpDevs | Where-Object { $_.Name -like "*$InterfaceDescription*" -or $_.Description -like "*$InterfaceDescription*" } | Select-Object -First 1
        } else {
            $pnpDevs | Select-Object -First 1
        }

        if ($matchedDev) {
            $result.Supported = $true
            # 只读查询电源管理
            $devId = $matchedDev.DeviceID.Replace('\', '\\')
            $wmiPower = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -Filter "InstanceName LIKE '%$devId%'" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($wmiPower) {
                $result.AllowComputerToTurnOffDevice = [bool]$wmiPower.Enable
                if ($result.AllowComputerToTurnOffDevice) {
                    $result.Warning = "[警告] 网卡启用了'允许计算机关闭此设备以节约电源'，休眠唤醒或低功耗切换时可能引发 Wi-Fi 断流或握手失败！"
                    $result.Guidance = "建议在 Windows '设备管理器 -> 网络适配器 -> 属性 -> 电源管理' 中取消勾选此项（本工具遵循只读原则，绝不自动篡改系统硬件节能配置）。"
                }
            } else {
                $result.AllowComputerToTurnOffDevice = $false
                $result.Guidance = "网卡未激活睡眠关闭节电特性，运行稳定。"
            }
        }
    } catch {
        $result.Guidance = "无法通过只读 WMI 枚举网卡节能配置: $($_.Exception.Message)"
    }
    return $result
}

function Get-WlanLinkQuality {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        Available        = $false
        InterfaceName    = $null
        SSID             = $null
        BSSID            = $null
        RadioType        = $null
        Band             = $null
        Channel          = $null
        ReceiveRateMbps  = $null
        TransmitRateMbps = $null
        SignalPercent    = $null
        EstimatedRssi    = $null
        Notes            = ""
    }

    try {
        $netshOut = netsh wlan show interfaces 2>&1
        $txt = ($netshOut -join "`n")

        if ($txt -match 'Access is denied|拒绝访问|Error 5') {
            $result.Notes = "Windows 11 位置隐私权限未向命令行开放，无法读取精确实时 SSID/BSSID，但不影响网络核心功能。"
            return $result
        }

        if ($txt -match 'State\s*:\s*connected|状态\s*:\s*已连接') {
            $result.Available = $true

            if ($txt -match 'Name\s*:\s*(.+)') { $result.InterfaceName = $matches[1].Trim() }
            if ($txt -match 'SSID\s*:\s*(.+)') {
                $rawSSID = $matches[1].Trim()
                $result.SSID = if ($rawSSID.Length -gt 2) { $rawSSID.Substring(0, 2) + "***" } else { "***" }
            }
            if ($txt -match 'BSSID\s*:\s*([0-9a-fA-F:]{17})') {
                $rawBSSID = $matches[1].Trim()
                $result.BSSID = $rawBSSID.Substring(0, 8) + ":**:**:**"
            }
            if ($txt -match 'Radio type\s*:\s*(.+)|无线电类型\s*:\s*(.+)') {
                $result.RadioType = ($matches[1] + $matches[2]).Trim()
            }
            if ($txt -match 'Band\s*:\s*(.+)|频带\s*:\s*(.+)') {
                $result.Band = ($matches[1] + $matches[2]).Trim()
            }
            if ($txt -match 'Channel\s*:\s*(\d+)|信道\s*:\s*(\d+)') {
                $result.Channel = [int]($matches[1] + $matches[2]).Trim()
            }
            if ($txt -match 'Receive rate \(Mbps\)\s*:\s*([\d\.]+)|接收速率 \(Mbps\)\s*:\s*([\d\.]+)') {
                $result.ReceiveRateMbps = [double]($matches[1] + $matches[2]).Trim()
            }
            if ($txt -match 'Transmit rate \(Mbps\)\s*:\s*([\d\.]+)|传输速率 \(Mbps\)\s*:\s*([\d\.]+)') {
                $result.TransmitRateMbps = [double]($matches[1] + $matches[2]).Trim()
            }
            if ($txt -match 'Signal\s*:\s*(\d+)%|信号\s*:\s*(\d+)%') {
                $sig = [int]($matches[1] + $matches[2]).Trim()
                $result.SignalPercent = $sig
                # 经验公式：RSSI = (Signal / 2) - 100
                $result.EstimatedRssi = [math]::Round(($sig / 2) - 100, 0)
            }

            $sigVal = if ($result.SignalPercent) { $result.SignalPercent } else { 100 }
            if ($sigVal -lt 50) {
                $result.Notes = "信号强度较弱 (<50%)，物理层重传率高，可能导致 IEEE 802.11 四次握手超时断网！"
            } else {
                $result.Notes = "无线射频链路质量优良，协商速率健康。"
            }
        } else {
            $result.Notes = "当前系统无处于已连接状态的无线 Wi-Fi 接口。"
        }
    } catch {
        $result.Notes = "执行 netsh wlan 查询时发生异常: $($_.Exception.Message)"
    }
    return $result
}

function Get-DhcpLeaseInfo {
    [CmdletBinding()]
    param(
        [int]$InterfaceIndex = 0
    )

    $result = [PSCustomObject]@{
        DHCPEnabled      = $false
        LeaseObtained    = $null
        LeaseExpires     = $null
        RemainingMinutes = $null
        T1RenewalTime    = $null
        T2RebindTime     = $null
        DHCPServer       = $null
        Notes            = ""
    }

    try {
        $wmiAdapters = @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPEnabled -eq $true })
        $target = if ($InterfaceIndex -gt 0) {
            $wmiAdapters | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex } | Select-Object -First 1
        } else {
            $wmiAdapters | Where-Object { $_.DHCPEnabled -eq $true } | Select-Object -First 1
        }

        if ($target -and $target.DHCPEnabled) {
            $result.DHCPEnabled = $true
            $result.DHCPServer = $target.DHCPServer
            $result.LeaseObtained = $target.DHCPLeaseObtained
            $result.LeaseExpires = $target.DHCPLeaseExpires

            if ($target.DHCPLeaseObtained -and $target.DHCPLeaseExpires) {
                $obtained = [datetime]$target.DHCPLeaseObtained
                $expires = [datetime]$target.DHCPLeaseExpires
                $totalSec = ($expires - $obtained).TotalSeconds
                $remSec = ($expires - (Get-Date)).TotalSeconds

                $result.RemainingMinutes = [math]::Round($remSec / 60, 1)
                $result.T1RenewalTime = $obtained.AddSeconds($totalSec * 0.50).ToString("yyyy-MM-dd HH:mm:ss")
                $result.T2RebindTime  = $obtained.AddSeconds($totalSec * 0.875).ToString("yyyy-MM-dd HH:mm:ss")

                if ($remSec -le 0) {
                    $result.Notes = "[警告] DHCP 租约已过期，系统正在依赖临时缓存或面临断网！"
                } elseif ($remSec -lt ($totalSec * 0.125)) {
                    $result.Notes = "[注意] 租约已越过 87.5% T2 阈值，进入广播 Rebind 状态。"
                } elseif ($remSec -lt ($totalSec * 0.50)) {
                    $result.Notes = "[正常] 租约已越过 50% T1 阈值，客户端正在按 RFC 2131 规范后台单播请求续订。"
                } else {
                    $result.Notes = "[正常] 租约处于初始稳定期。"
                }
            }
        } elseif ($target) {
            $result.Notes = "目标适配器为静态 IP 配置 (DHCP 未启用)。"
        } else {
            $result.Notes = "未找到处于 IPEnabled 状态的 DHCP 网络适配器。"
        }
    } catch {
        $result.Notes = "查询 DHCP 租约信息异常: $($_.Exception.Message)"
    }
    return $result
}

function Get-NcsiStatus {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        ProfileName         = "Unknown"
        IPv4Connectivity    = "Unknown"
        IPv6Connectivity    = "Unknown"
        ProbeWebUrl         = "http://www.msftconnecttest.com/connecttest.txt"
        ActiveWebProbeState = "Unknown"
        NlaSvcStatus        = "Unknown"
        Notes               = ""
    }

    try {
        $prof = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($prof) {
            $result.ProfileName = $prof.Name
            $result.IPv4Connectivity = $prof.IPv4Connectivity.ToString()
            $result.IPv6Connectivity = $prof.IPv6Connectivity.ToString()
        }

        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet"
        if (Test-Path $regPath) {
            $reg = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            if ($reg -and $reg.ActiveWebProbeHost) {
                $result.ProbeWebUrl = "http://$($reg.ActiveWebProbeHost)/$($reg.ActiveWebProbePath)"
            }
            if ($reg -and ($null -ne $reg.EnableActiveProbing)) {
                $result.ActiveWebProbeState = if ($reg.EnableActiveProbing -eq 1) { "已启用 (1)" } else { "已禁用 (0)" }
            }
        }

        $svc = Get-Service -Name "NlaSvc" -ErrorAction SilentlyContinue
        if ($svc) {
            $result.NlaSvcStatus = $svc.Status.ToString()
        }

        if ($result.IPv4Connectivity -eq 'Internet') {
            $result.Notes = "Windows NCSI 判定互联网连接正常。"
        } else {
            $result.Notes = "Windows NCSI 判定受限或无互联网访问（任务栏小地球）。若真实浏览器仍能上网，通常为微软探针探测超时或企业/学校网络认证拦截。"
        }
    } catch {
        $result.Notes = "查询 NCSI 状态异常: $($_.Exception.Message)"
    }
    return $result
}

function Get-CoreNetworkServicesStatus {
    [CmdletBinding()]
    param()

    $serviceDefs = @(
        @{ Name = "Dhcp"; Role = "动态主机配置协议客户端 (负责获取与续租局域网 IP/网关/DNS 地址)" },
        @{ Name = "Dnscache"; Role = "DNS 客户端缓存服务 (负责域名集中解析缓存与跨进程 DNS 优化)" },
        @{ Name = "nsi"; Role = "网络存储接口服务 (底层网络状态变更统一收集与路由表消息分发核心)" },
        @{ Name = "Wlansvc"; Role = "WLAN AutoConfig (负责 Wi-Fi 无线网卡驱动协同、热点扫描与 WPA 安全认证)" },
        @{ Name = "NlaSvc"; Role = "网络位置识别服务 (负责识别专用/公用网络拓扑，驱动 NCSI 连通性判定)" },
        @{ Name = "WinHttpAutoProxySvc"; Role = "Windows HTTP 代理自动发现服务 (负责系统与桌面应用 WPAD/PAC 脚本解析)" }
    )

    $results = @()
    foreach ($sd in $serviceDefs) {
        $svc = Get-Service -Name $sd.Name -ErrorAction SilentlyContinue
        $status = if ($svc) { $svc.Status.ToString() } else { "NotInstalled" }
        $startType = if ($svc) { $svc.StartType.ToString() } else { "Unknown" }

        $results += [PSCustomObject]@{
            ServiceName = $sd.Name
            Status      = $status
            StartType   = $startType
            Role        = $sd.Role
            IsHealthy   = ($status -eq 'Running')
        }
    }
    return $results
}

function Test-NetworkReachability {
    [CmdletBinding()]
    param(
        [string]$Gateway = $null
    )

    $result = [PSCustomObject]@{
        GatewayReachable = $false
        GatewayLatencyMs = $null
        TcpTargets       = @()
        DnsResolutions   = @()
        OverallState     = "Unknown"
    }

    # 1. 网关 ICMP
    if ($Gateway -and $Gateway -ne '0.0.0.0') {
        try {
            $p = New-Object System.Net.NetworkInformation.Ping
            $reply = $p.Send($Gateway, 1000)
            if ($reply.Status -eq 'Success') {
                $result.GatewayReachable = $true
                $result.GatewayLatencyMs = $reply.RoundtripTime
            }
        } catch { }
    }

    # 2. 独立公网 TCP 直连
    $targets = @(
        @{ Host = "223.5.5.5"; Port = 53; Name = "AliDNS Public DNS (TCP 53)" },
        @{ Host = "119.29.29.29"; Port = 53; Name = "DNSPod Public DNS (TCP 53)" },
        @{ Host = "180.101.50.188"; Port = 443; Name = "Baidu Public HTTPS (TCP 443)" },
        @{ Host = "203.107.1.1"; Port = 80; Name = "AliCloud Public HTTP (TCP 80)" }
    )

    $tcpSuccessCount = 0
    foreach ($t in $targets) {
        $tcpItem = [PSCustomObject]@{
            Target    = "$($t.Host):$($t.Port)"
            Name      = $t.Name
            Success   = $false
            LatencyMs = $null
        }
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $iar = $client.BeginConnect($t.Host, $t.Port, $null, $null)
            $wait = $iar.AsyncWaitHandle.WaitOne(1500, $false)
            $sw.Stop()
            if ($wait -and $client.Connected) {
                $client.EndConnect($iar)
                $tcpItem.Success = $true
                $tcpItem.LatencyMs = $sw.ElapsedMilliseconds
                $tcpSuccessCount++
            }
            $client.Close()
        } catch { }
        $result.TcpTargets += $tcpItem
    }

    # 3. DNS 解析
    $domains = @("www.baidu.com", "www.aliyun.com")
    $dnsSuccessCount = 0
    foreach ($d in $domains) {
        $dnsItem = [PSCustomObject]@{
            Domain    = $d
            Success   = $false
            Addresses = @()
        }
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($d)
            if (@($addrs).Count -gt 0) {
                $dnsItem.Success = $true
                $dnsItem.Addresses = @($addrs | ForEach-Object { $_.IPAddressToString })
                $dnsSuccessCount++
            }
        } catch { }
        $result.DnsResolutions += $dnsItem
    }

    if ($tcpSuccessCount -ge 2 -and $dnsSuccessCount -ge 1) {
        $result.OverallState = "Healthy (网络完全连通)"
    } elseif ($tcpSuccessCount -ge 1) {
        $result.OverallState = "Degraded (TCP 直连通畅，但部分 DNS 或目标异常)"
    } else {
        $result.OverallState = "Disconnected (外网链路不可达)"
    }

    return $result
}

function Get-ProxyConfiguration {
    [CmdletBinding()]
    param()

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $props = if (Test-Path $regPath) { Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue } else { $null }

    $pEnable = if ($props -and $props.PSObject.Properties['ProxyEnable'] -and ($null -ne $props.ProxyEnable)) { [int]$props.ProxyEnable } else { 0 }
    $pServer = if ($props -and $props.PSObject.Properties['ProxyServer'] -and ($null -ne $props.ProxyServer)) { [string]$props.ProxyServer } else { "[未配置]" }
    $pAuto   = if ($props -and $props.PSObject.Properties['AutoConfigURL'] -and ($null -ne $props.AutoConfigURL)) { [string]$props.AutoConfigURL } else { "[未配置]" }
    $pOver   = if ($props -and $props.PSObject.Properties['ProxyOverride'] -and ($null -ne $props.ProxyOverride)) { [string]$props.ProxyOverride } else { "[未配置]" }

    $winInet = [PSCustomObject]@{
        ProxyEnable   = $pEnable
        ProxyServer   = $pServer
        AutoConfigURL = $pAuto
        ProxyOverride = $pOver
    }

    $winHttpRaw = (netsh winhttp show proxy 2>&1) -join "`n"
    $winHttpMode = if ($winHttpRaw -match 'Direct access|直接访问') { "Direct (直连)" } else { "Configured (已配置)" }

    return [PSCustomObject]@{
        WinInet     = $winInet
        WinHttpMode = $winHttpMode
        WinHttpRaw  = $winHttpRaw
    }
}

function Invoke-FullDiagnostic {
    [CmdletBinding()]
    param()

    Write-Host "=======================================================================" -ForegroundColor Cyan
    Write-Host "            Windows 10/11 便携网络诊断：12 层全息只读检测             " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan

    # 1. 看门狗互斥
    Write-Host "`n[第 1 层] 本地网络看门狗协同状态:" -ForegroundColor Yellow
    $wd = Test-LocalWatchdogConflict
    if ($wd.ScheduledTaskRunning) {
        Write-Host "   - [提醒] $($wd.Details)" -ForegroundColor Cyan
    } else {
        Write-Host "   - [正常] $($wd.Details)" -ForegroundColor Green
    }

    # 2. IPv4 默认路由
    Write-Host "`n[第 2 层] IPv4 默认路由与网关检测:" -ForegroundColor Yellow
    $route = Get-DefaultIPv4RouteAndGateway
    if ($route.Found) {
        Write-Host "   - 默认路由: 0.0.0.0/0 via $($route.NextHop)" -ForegroundColor Green
        Write-Host "   - 出口接口: $($route.InterfaceAlias) (索引: $($route.InterfaceIndex))"
        Write-Host "   - 有效度量值: $($route.EffectiveMetric) (路由度量: $($route.RouteMetric) + 接口度量: $($route.InterfaceMetric))"
    } else {
        Write-Host "   - [异常] 未找到 IPv4 默认路由 (0.0.0.0/0)！系统当前无外网路由引导出口。" -ForegroundColor Red
    }

    # 3. 物理活动适配器
    Write-Host "`n[第 3 层] 出口物理网络适配器核验:" -ForegroundColor Yellow
    $prefIndex = if ($route.Found) { $route.InterfaceIndex } else { 0 }
    $nic = Get-ActivePhysicalAdapter -PreferredInterfaceIndex $prefIndex
    if ($nic.Found) {
        Write-Host "   - 识别网卡: $($nic.Name) (状态: $($nic.Status))" -ForegroundColor Green
        Write-Host "   - 硬件描述: $($nic.InterfaceDescription)"
        Write-Host "   - 接口索引: $($nic.InterfaceIndex) | GUID: $($nic.InterfaceGuid)"
        Write-Host "   - 物理硬件: $($nic.HardwareInterface) (已排除虚拟 TUN/TAP/VPN/Hyper-V)"
    } else {
        Write-Host "   - [警告] 未识别到活动物理硬件网卡！" -ForegroundColor Yellow
    }

    # 4. IPv6 双栈状态与黑洞排查
    Write-Host "`n[第 4 层] IPv6 双栈与黑洞探测 (RFC 6555 / Happy Eyeballs):" -ForegroundColor Yellow
    $v6 = Get-IPv6Status
    $v6Color = if ($v6.HasDefaultRoute -and -not $v6.HasGlobalV6) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green }
    Write-Host "   - 判定状态: $($v6.StateDescription)" -ForegroundColor $v6Color
    if ($v6.HasDefaultRoute) {
        Write-Host "   - IPv6 网关: $($v6.Gateway) (出口索引: $($v6.InterfaceIndex))"
    }

    # 5. 网卡电源管理节能检查
    Write-Host "`n[第 5 层] 网卡电源管理节能机制 (防 D3 低功耗掉线):" -ForegroundColor Yellow
    $descParam = if ($nic.Found) { $nic.InterfaceDescription } else { "" }
    $pwr = Get-AdapterPowerManagementStatus -InterfaceDescription $descParam
    if ($pwr.AllowComputerToTurnOffDevice -eq $true) {
        Write-Host "   - $($pwr.Warning)" -ForegroundColor Yellow
        Write-Host "   - $($pwr.Guidance)" -ForegroundColor Gray
    } else {
        Write-Host "   - $($pwr.Guidance)" -ForegroundColor Green
    }

    # 6. 无线链路质量与协商速率
    Write-Host "`n[第 6 层] 无线 Wi-Fi 射频链路与协商状态:" -ForegroundColor Yellow
    $wlan = Get-WlanLinkQuality
    if ($wlan.Available) {
        Write-Host "   - 连接热点: SSID=$($wlan.SSID) | BSSID=$($wlan.BSSID)" -ForegroundColor Green
        Write-Host "   - 频段信道: $($wlan.Band) (信道 $($wlan.Channel)) | 协议标准: $($wlan.RadioType)"
        Write-Host "   - 协商速率: 接收 $($wlan.ReceiveRateMbps) Mbps / 传输 $($wlan.TransmitRateMbps) Mbps"
        Write-Host "   - 信号强度: $($wlan.SignalPercent)% (估算 RSSI: $($wlan.EstimatedRssi) dBm)"
        $wlanColor = if ($wlan.SignalPercent -lt 50) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green }
        Write-Host "   - 链路评价: $($wlan.Notes)" -ForegroundColor $wlanColor
    } else {
        Write-Host "   - $($wlan.Notes)" -ForegroundColor Gray
    }

    # 7. IP 配置与 DHCP 租约生命周期
    Write-Host "`n[第 7 层] IP 与 DHCP 租约生命周期 (RFC 2131):" -ForegroundColor Yellow
    $ifIdxParam = if ($nic.Found) { $nic.InterfaceIndex } else { 0 }
    $dhcp = Get-DhcpLeaseInfo -InterfaceIndex $ifIdxParam
    if ($dhcp.DHCPEnabled) {
        Write-Host "   - DHCP 模式: 已启用 (DHCP 服务器: $($dhcp.DHCPServer))" -ForegroundColor Green
        Write-Host "   - 租约获取: $($dhcp.LeaseObtained) | 到期: $($dhcp.LeaseExpires) (剩余 $($dhcp.RemainingMinutes) 分钟)"
        Write-Host "   - T1 续租点 (50%): $($dhcp.T1RenewalTime) | T2 重绑定 (87.5%): $($dhcp.T2RebindTime)"
        Write-Host "   - 生命周期状态: $($dhcp.Notes)" -ForegroundColor Green
    } else {
        Write-Host "   - DHCP 模式: 未启用 (静态 IP 或虚拟网卡)" -ForegroundColor Yellow
    }

    # 8. NCSI 探针与连通性判定
    Write-Host "`n[第 8 层] Windows NCSI 连通性判定与系统探针:" -ForegroundColor Yellow
    $ncsi = Get-NcsiStatus
    Write-Host "   - 网络配置文件: $($ncsi.ProfileName) (IPv4: $($ncsi.IPv4Connectivity), IPv6: $($ncsi.IPv6Connectivity))" -ForegroundColor Green
    Write-Host "   - 探针配置: $($ncsi.ActiveWebProbeState) | 探针 URL: $($ncsi.ProbeWebUrl)"
    Write-Host "   - NlaSvc 服务: $($ncsi.NlaSvcStatus)"
    Write-Host "   - 综合判定: $($ncsi.Notes)" -ForegroundColor Gray

    # 9. 网关 ICMP 响应与公网 TCP 直连
    Write-Host "`n[第 9 层] 网关 ICMP 响应与 4 公网独立目标 TCP 握手:" -ForegroundColor Yellow
    $gwIp = if ($route.Found) { $route.NextHop } else { $null }
    $reach = Test-NetworkReachability -Gateway $gwIp
    if ($reach.GatewayReachable) {
        Write-Host "   - 网关 ICMP: 响应正常 (延迟: $($reach.GatewayLatencyMs) ms)" -ForegroundColor Green
    } else {
        Write-Host "   - 网关 ICMP: 无响应或网关阻断 ICMP (企业/租户环境常见，不等于断网)" -ForegroundColor Gray
    }
    foreach ($t in $reach.TcpTargets) {
        if ($t.Success) {
            Write-Host ("   - TCP 握手成功: {0,-28} | 握手延迟: {1} ms" -f $t.Name, $t.LatencyMs) -ForegroundColor Green
        } else {
            Write-Host ("   - TCP 握手失败: {0,-28} | 握手超时" -f $t.Name) -ForegroundColor Red
        }
    }

    # 10. DNS 解析验证
    Write-Host "`n[第 10 层] DNS 域名解析验证:" -ForegroundColor Yellow
    foreach ($d in $reach.DnsResolutions) {
        if ($d.Success) {
            Write-Host ("   - 解析成功: {0,-20} -> {1}" -f $d.Domain, ($d.Addresses -join ', ')) -ForegroundColor Green
        } else {
            Write-Host ("   - 解析失败: {0,-20} -> 查询超时或 DNS 服务器未响应" -f $d.Domain) -ForegroundColor Red
        }
    }

    # 11. WinINET 与 WinHTTP 代理状态
    Write-Host "`n[第 11 层] 代理配置 (WinINET 当前用户 / WinHTTP 系统服务):" -ForegroundColor Yellow
    $proxy = Get-ProxyConfiguration
    $pEn = if ($proxy.WinInet.ProxyEnable -eq 1) { "已启用 (1)" } else { "已禁用 (0)" }
    Write-Host "   - WinINET 手动代理: $pEn | 代理服务器: $($proxy.WinInet.ProxyServer)"
    Write-Host "   - WinINET 自动配置: $($proxy.WinInet.AutoConfigURL)"
    Write-Host "   - WinHTTP 服务代理: $($proxy.WinHttpMode)"

    # 12. 6 大核心网络服务与职责
    Write-Host "`n[第 12 层] 6 大核心系统网络服务运行状态与职责:" -ForegroundColor Yellow
    $svcs = Get-CoreNetworkServicesStatus
    foreach ($s in $svcs) {
        $stColor = if ($s.IsHealthy) { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
        Write-Host ("   - [{0,-7}] {1,-20} (启动: {2,-8}) | {3}" -f $s.Status, $s.ServiceName, $s.StartType, $s.Role) -ForegroundColor $stColor
    }

    Write-Host "`n=======================================================================" -ForegroundColor Cyan
    $overallColor = if ($reach.OverallState -match 'Healthy') { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
    Write-Host " 综合诊断结论: $($reach.OverallState)" -ForegroundColor $overallColor
    Write-Host "=======================================================================" -ForegroundColor Cyan

    return [PSCustomObject]@{
        Watchdog       = $wd
        Route          = $route
        Adapter        = $nic
        IPv6           = $v6
        Power          = $pwr
        Wlan           = $wlan
        Dhcp           = $dhcp
        Ncsi           = $ncsi
        Reachability   = $reach
        Proxy          = $proxy
        Services       = $svcs
    }
}

Export-ModuleMember -Function @(
    'Test-LocalWatchdogConflict',
    'Get-DefaultIPv4RouteAndGateway',
    'Get-ActivePhysicalAdapter',
    'Get-IPv6Status',
    'Get-AdapterPowerManagementStatus',
    'Get-WlanLinkQuality',
    'Get-DhcpLeaseInfo',
    'Get-NcsiStatus',
    'Get-CoreNetworkServicesStatus',
    'Test-NetworkReachability',
    'Get-ProxyConfiguration',
    'Invoke-FullDiagnostic'
)

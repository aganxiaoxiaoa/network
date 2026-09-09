# ==============================================================================
# NetworkDiagnostics.psm1
# 便携网络恢复与诊断工具箱 - 分层只读网络诊断模块
# 严格遵循只读原则：不改变任何系统配置、不触碰物理网卡状态、不写入非临时配置
# ==============================================================================

Set-StrictMode -Version 2.0

function Get-ToolConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot "..\NetworkRecovery.Config.psd1")
    )
    if (Test-Path $ConfigPath) {
        return Import-PowerShellDataFile -Path $ConfigPath
    }
    return @{
        PublicWanTargets = @("223.5.5.5:53", "119.29.29.29:53", "114.114.114.114:53", "www.baidu.com:443")
        TcpProbeTimeoutMs = 5000
        DnsTestDomain = "www.microsoft.com"
        CoreNetworkServices = @("Dhcp", "Dnscache", "nsi", "Wlansvc")
    }
}

function Get-DefaultRouteInfo {
    [CmdletBinding()]
    param()

    try {
        $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction Stop |
                    Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric })

        if ($routes.Count -eq 0) {
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
        # 1. 优先检查 PreferredInterfaceIndex (通常为最优默认路由所对应的接口)
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

        # 2. 若默认路由接口并非物理卡或未指定，扫描所有物理状态为 Up 的网络适配器
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

        # 3. 若无 Up 状态的物理网卡，退化为查找任意物理网卡
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

function Test-DynamicGateway {
    [CmdletBinding()]
    param(
        [string]$Gateway
    )

    if ([string]::IsNullOrWhiteSpace($Gateway) -or $Gateway -eq '0.0.0.0') {
        return [PSCustomObject]@{
            Gateway   = "未指定或无网关"
            PingOk    = $false
            LatencyMs = -1
            Note      = "无有效网关地址"
        }
    }

    try {
        $ping = Test-Connection -ComputerName $Gateway -Count 1 -Quiet -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            Gateway   = $Gateway
            PingOk    = [bool]$ping
            LatencyMs = 0
            Note      = if ($ping) { "网关响应正常" } else { "网关未响应 ICMP (可能仅为防火墙禁 Ping 或局域网流量控制，不直接等同于断网)" }
        }
    } catch {
        return [PSCustomObject]@{
            Gateway   = $Gateway
            PingOk    = $false
            LatencyMs = -1
            Note      = "Ping 测试异常: $($_.Exception.Message)"
        }
    }
}

function Test-RawTcpTargets {
    [CmdletBinding()]
    param(
        [string[]]$Targets,
        [int]$TimeoutMs = 5000
    )

    $results = @()
    $anySuccess = $false

    foreach ($tgt in $Targets) {
        $parts = $tgt -split ':'
        if ($parts.Count -ne 2) { continue }
        $hostName = $parts[0].Trim()
        $port = [int]$parts[1]

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tcpClient = $null
        $connected = $false
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $tcpClient.BeginConnect($hostName, $port, $null, $null)
            $waitSuccess = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
            if ($waitSuccess -and $tcpClient.Connected) {
                $tcpClient.EndConnect($asyncResult)
                $connected = $true
                $anySuccess = $true
            }
        } catch {
            $connected = $false
        } finally {
            $sw.Stop()
            if ($tcpClient -ne $null) {
                $tcpClient.Close()
            }
        }

        $results += [PSCustomObject]@{
            Target    = $tgt
            Connected = $connected
            ElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        }
    }

    return [PSCustomObject]@{
        WanReachable = $anySuccess
        Details      = $results
    }
}

function Test-DnsResolution {
    [CmdletBinding()]
    param(
        [string]$Domain = "www.microsoft.com"
    )

    try {
        $dnsRes = Resolve-DnsName -Name $Domain -Type A -QuickTimeout -ErrorAction Stop
        $ips = ($dnsRes | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress) -join ', '
        return [PSCustomObject]@{
            Resolves  = $true
            Domain    = $Domain
            Addresses = $ips
            Error     = $null
        }
    } catch {
        try {
            $entry = [System.Net.Dns]::GetHostEntry($Domain)
            $ips = ($entry.AddressList | Select-Object -ExpandProperty IPAddressToString) -join ', '
            return [PSCustomObject]@{
                Resolves  = $true
                Domain    = $Domain
                Addresses = $ips
                Error     = "Resolve-DnsName 失败，.NET 备用解析成功"
            }
        } catch {
            return [PSCustomObject]@{
                Resolves  = $false
                Domain    = $Domain
                Addresses = $null
                Error     = $_.Exception.Message
            }
        }
    }
}

function Get-ProxyStatus {
    [CmdletBinding()]
    param()

    # 1. 当前用户 WinINET 代理 (注册表)
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

    # 2. WinHTTP 代理 (只读记录，严禁修改)
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
        $dnsServers = if ($dnsInfo -and $dnsInfo.ServerAddresses) { @($dnsInfo.ServerAddresses) } else { @() }

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

function Invoke-FullDiagnostic {
    [CmdletBinding()]
    param()

    $cfg = Get-ToolConfig

    Write-Host "=======================================================================" -ForegroundColor Cyan
    Write-Host "                正在执行分层只读网络健康诊断...                         " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan

    # 1. 默认路由与网关
    $routeInfo = Get-DefaultRouteInfo
    Write-Host "[1/8] 默认路由探测:" -ForegroundColor Yellow
    if ($routeInfo.HasDefaultRoute) {
        Write-Host "   - 默认路由: 0.0.0.0/0 存在" -ForegroundColor Green
        Write-Host "   - 接口索引: $($routeInfo.InterfaceIndex) ($($routeInfo.InterfaceAlias))"
        Write-Host "   - 下一跳网关: $($routeInfo.NextHop)"
        Write-Host "   - 有效跃点 (Metric): $($routeInfo.EffectiveMetric) (Route: $($routeInfo.RouteMetric) + Intf: $($routeInfo.InterfaceMetric))"
    } else {
        Write-Host "   - [警告] 未检测到有效的 IPv4 默认路由 (0.0.0.0/0)" -ForegroundColor Red
    }

    # 2. 物理适配器核验
    $nicIndex = if ($routeInfo.HasDefaultRoute) { [int]$routeInfo.InterfaceIndex } else { 0 }
    $nic = Get-ActivePhysicalAdapter -PreferredInterfaceIndex $nicIndex
    Write-Host "`n[2/8] 活动网络适配器核验:" -ForegroundColor Yellow
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

    # 3. IP 与 DHCP 检查
    $ipDetails = if ($nic.Found) { Get-AdapterIpDetails -InterfaceIndex $nic.InterfaceIndex } else { Get-AdapterIpDetails -InterfaceIndex 0 }
    Write-Host "`n[3/8] IP 配置与 DHCP 分配:" -ForegroundColor Yellow
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

    # 4. 网关连通性 (ICMP Ping)
    $gwTest = Test-DynamicGateway -Gateway $routeInfo.NextHop
    Write-Host "`n[4/8] 动态网关连通性:" -ForegroundColor Yellow
    if ($gwTest.PingOk) {
        Write-Host "   - 网关 ($($gwTest.Gateway)) ICMP 连通: 正常响应" -ForegroundColor Green
    } else {
        Write-Host "   - 网关 ($($gwTest.Gateway)) ICMP 连通: $($gwTest.Note)" -ForegroundColor Yellow
    }

    # 5. 公网直连 TCP 握手探测 (绕过代理)
    Write-Host "`n[5/8] 公网直连 TCP 握手 (绕过系统代理，4 个不同运营商/端口目标):" -ForegroundColor Yellow
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

    # 6. DNS 域名解析
    Write-Host "`n[6/8] 域名系统 (DNS) 解析测试:" -ForegroundColor Yellow
    $dnsProbe = Test-DnsResolution -Domain $cfg.DnsTestDomain
    if ($dnsProbe.Resolves) {
        Write-Host "   - 测试域名: $($dnsProbe.Domain) -> 解析为: $($dnsProbe.Addresses)" -ForegroundColor Green
    } else {
        Write-Host "   - 测试域名: $($dnsProbe.Domain) -> 解析失败: $($dnsProbe.Error)" -ForegroundColor Red
    }

    # 7. 代理配置检查
    Write-Host "`n[7/8] 系统代理配置 (WinINET / WinHTTP):" -ForegroundColor Yellow
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

    # 8. 核心网络服务
    Write-Host "`n[8/8] Windows 核心网络服务状态:" -ForegroundColor Yellow
    $services = Get-NetworkServiceStatus -ServiceNames $cfg.CoreNetworkServices
    foreach ($s in $services) {
        $sColor = if ($s.Status -eq 'Running') { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-Host ("   - 服务 {0,-12} ({1,-20}): {2,-10} (启动类型: {3})" -f $s.Name, $s.DisplayName, $s.Status, $s.StartType) -ForegroundColor $sColor
    }

    Write-Host "`n=======================================================================" -ForegroundColor Cyan
    Write-Host "                        诊断完成                                       " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan

    return [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        RouteInfo    = $routeInfo
        Adapter      = $nic
        IpDetails    = $ipDetails
        GatewayTest  = $gwTest
        TcpProbe     = $tcpProbe
        DnsProbe     = $dnsProbe
        ProxyStatus  = $proxy
        Services     = $services
    }
}

Export-ModuleMember -Function @(
    'Get-ToolConfig',
    'Get-DefaultRouteInfo',
    'Get-ActivePhysicalAdapter',
    'Test-DynamicGateway',
    'Test-RawTcpTargets',
    'Test-DnsResolution',
    'Get-ProxyStatus',
    'Get-AdapterIpDetails',
    'Get-NetworkServiceStatus',
    'Get-WlanDiagnostics',
    'Invoke-FullDiagnostic'
)

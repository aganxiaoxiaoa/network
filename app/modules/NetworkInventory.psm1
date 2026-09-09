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
        CoreNetworkServices = @("Dhcp", "Dnscache", "nsi", "Wlansvc")
        MinFreeSpaceMBForDrivers = 500
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

    # 检查 Clash/ProxyStack 状态
    $proxyProcs = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match "clash-verge|verge-mihomo|ProxyBridge"
    }

    return [PSCustomObject]@{
        TaskExists    = ($null -ne $task)
        TaskState     = $taskState
        ProcRunning   = $procRunning
        ProcessId     = $procId
        ProxyStackCount = $proxyProcs.Count
        IsProtected   = ($taskState -eq 'Running' -or $procRunning)
    }
}

Export-ModuleMember -Function @(
    'Get-ToolConfig',
    'Get-DefaultRouteInfo',
    'Get-ActivePhysicalAdapter',
    'Get-AdapterIpDetails',
    'Get-ProxyStatus',
    'Get-NetworkServiceStatus',
    'Get-WlanDiagnostics',
    'Get-LocalWatchdogStatus'
)

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

function Get-SystemSleepCapability {
    [CmdletBinding()]
    param()

    try {
        $raw = (powercfg /a 2>&1) | Out-String

        $availableSection = ""
        $unavailableSection = ""
        if ($raw -match "(?s)此系统上有以下睡眠状态:(.*?)(此系统上没有以下睡眠状态:|$)") {
            $availableSection = $matches[1]
        } elseif ($raw -match "(?s)The following sleep states are available on this system:(.*?)(The following sleep states are not available on this system:|$)") {
            $availableSection = $matches[1]
        }
        if ($raw -match "(?s)(此系统上没有以下睡眠状态|The following sleep states are not available on this system):(.*?)$") {
            $unavailableSection = $matches[2]
        }

        $s0Available = ($availableSection -match 'S0')
        $s3Available = ($availableSection -match 'S3')

        $isModernStandby = if ($s0Available) { $true } elseif ($s3Available) { $false } else { "Unknown" }

        $unavailableList = @()
        if (-not [string]::IsNullOrWhiteSpace($unavailableSection)) {
            $pattern = "(?m)^\s{4}(待机\s*\([^)]+\)|休眠|混合睡眠|快速启动|Standby\s*\([^)]+\)|Hibernate|Hybrid\s*Sleep|Fast\s*Startup)"
            $blocks = [regex]::Split($unavailableSection, $pattern)
            for ($i = 1; $i -lt @($blocks).Count; $i += 2) {
                $stateName = $blocks[$i].Trim()
                $reasonText = if ($i + 1 -lt @($blocks).Count) { $blocks[$i+1].Trim() } else { "" }
                $unavailableList += [PSCustomObject]@{
                    State  = $stateName
                    Reason = ($reasonText -replace '\r?\n\s*', ' ')
                }
            }
        }

        return [PSCustomObject]@{
            IsModernStandby   = $isModernStandby
            SupportsS0        = $s0Available
            SupportsS3        = $s3Available
            UnavailableStates = @($unavailableList)
            RawOutput         = $raw.Trim()
        }
    } catch {
        return [PSCustomObject]@{
            IsModernStandby   = "Unknown"
            SupportsS0        = $false
            SupportsS3        = $false
            UnavailableStates = @()
            RawOutput         = $_.Exception.Message
        }
    }
}

function Get-AdapterAdvancedPowerProperties {
    [CmdletBinding()]
    param(
        [string]$AdapterName,
        [array]$Keywords = @(),
        [array]$AttentionKeywords = @(),
        [array]$NormalKeywords = @(),
        [array]$EnumKeywords = @(),
        [string]$LogDir = ""
    )

    if ([string]::IsNullOrWhiteSpace($AdapterName)) {
        return [PSCustomObject]@{
            Found                  = $false
            AdapterName            = ""
            Error                  = "未指定网卡名称"
            TotalPropertiesCount   = 0
            PowerRelatedProperties = @()
            AllProperties          = @()
            PowerRelatedCount      = 0
            EnabledCount           = 0
            AttentionEnabledCount  = 0
            NormalEnabledCount     = 0
            EnumCount              = 0
            LogPath                = $null
        }
    }

    # 预检网卡是否存在
    $nic = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    if (-not $nic) {
        return [PSCustomObject]@{
            Found                  = $false
            AdapterName            = $AdapterName
            Error                  = "未找到该网卡: $AdapterName"
            TotalPropertiesCount   = 0
            PowerRelatedProperties = @()
            AllProperties          = @()
            PowerRelatedCount      = 0
            EnabledCount           = 0
            AttentionEnabledCount  = 0
            NormalEnabledCount     = 0
            EnumCount              = 0
            LogPath                = $null
        }
    }

    # 配置回退兼容：若未显式提供分类关键字且提供了 Keywords，则将 Keywords 视为 AttentionKeywords
    $effectiveAttention = if (@($AttentionKeywords).Count -gt 0) {
        $AttentionKeywords
    } elseif (@($Keywords).Count -gt 0 -and @($NormalKeywords).Count -eq 0 -and @($EnumKeywords).Count -eq 0) {
        $Keywords
    } else {
        @()
    }
    $effectiveNormal = @($NormalKeywords)
    $effectiveEnum   = @($EnumKeywords)

    try {
        $rawProps = @(Get-NetAdapterAdvancedProperty -Name $AdapterName -ErrorAction SilentlyContinue)
        $allPropsList = @()
        $powerPropsList = @()
        $attentionEnabledCount = 0
        $normalEnabledCount = 0
        $enumCount = 0

        # 全量遍历所有属性
        foreach ($p in $rawProps) {
            $dispName = if ($p -and $p.PSObject.Properties['DisplayName']) { [string]$p.DisplayName } else { "" }
            $dispVal  = if ($p -and $p.PSObject.Properties['DisplayValue']) { [string]$p.DisplayValue } else { "" }
            $regKey   = if ($p -and $p.PSObject.Properties['RegistryKeyword']) { [string]$p.RegistryKeyword } else { "" }
            $regVal   = if ($p -and $p.PSObject.Properties['RegistryValue']) { [string]$p.RegistryValue } else { "" }

            # 1. 匹配需关注激进省电类
            $matchedAttention = @()
            foreach ($kw in $effectiveAttention) {
                if (-not [string]::IsNullOrWhiteSpace($kw)) {
                    if ($dispName.IndexOf($kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        $regKey.IndexOf($kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $matchedAttention += $kw
                    }
                }
            }

            # 2. 匹配正常类睡眠/网络卸载类
            $matchedNormal = @()
            foreach ($kw in $effectiveNormal) {
                if (-not [string]::IsNullOrWhiteSpace($kw)) {
                    if ($dispName.IndexOf($kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        $regKey.IndexOf($kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $matchedNormal += $kw
                    }
                }
            }

            # 3. 匹配多值枚举选择型
            $matchedEnum = @()
            foreach ($kw in $effectiveEnum) {
                if (-not [string]::IsNullOrWhiteSpace($kw)) {
                    if ($dispName.IndexOf($kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        $regKey.IndexOf($kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $matchedEnum += $kw
                    }
                }
            }

            # 语义化分类与布尔状态判定 (严格移除 ^1(\.|$) 避免将 1. 无首选项 / 1. 最高 误判为启用)
            $category = "Regular"
            $isPowerRelated = $false
            $matchedKeywords = @()
            $isEnabled = $false
            $statusText = "[常规属性]"

            if (@($matchedAttention).Count -gt 0) {
                $category = "Attention"
                $isPowerRelated = $true
                $matchedKeywords = $matchedAttention
                $isEnabled = ($dispVal -match '已启用|Enabled|开启|Active|Yes|True') -and ($dispVal -notmatch '已禁用|Disabled|关闭|No|False')
                if ($isEnabled) {
                    $attentionEnabledCount++
                    $statusText = "[需关注-已开启]"
                } else {
                    $statusText = "[需关注-已关闭]"
                }
            } elseif (@($matchedNormal).Count -gt 0) {
                $category = "Normal"
                $isPowerRelated = $true
                $matchedKeywords = $matchedNormal
                $isEnabled = ($dispVal -match '已启用|Enabled|开启|Active|Yes|True') -and ($dispVal -notmatch '已禁用|Disabled|关闭|No|False')
                if ($isEnabled) {
                    $normalEnabledCount++
                    $statusText = "[正常类-已开启]"
                } else {
                    $statusText = "[正常类-已关闭]"
                }
            } elseif (@($matchedEnum).Count -gt 0) {
                $category = "Enum"
                $isPowerRelated = $true
                $matchedKeywords = $matchedEnum
                $isEnabled = $false
                $enumCount++
                $statusText = "[枚举项]"
            }

            $propObj = [PSCustomObject]@{
                DisplayName           = $dispName
                DisplayValue          = $dispVal
                RegistryKeyword       = $regKey
                RegistryValue         = $regVal
                Category              = $category
                IsPowerRelated        = $isPowerRelated
                MatchedKeywords       = @($matchedKeywords)
                IsEnabled             = $isEnabled
                StatusText            = $statusText
            }

            if ($isPowerRelated) {
                $powerPropsList += $propObj
            }
            $allPropsList += $propObj
        }

        # 写入全量属性日志至 logs\ (若指定了有效目录)
        $logPath = $null
        if (-not [string]::IsNullOrWhiteSpace($LogDir) -and (Test-Path $LogDir)) {
            $ts = (Get-Date).ToString("yyyyMMdd_HHmmss")
            $logPath = Join-Path $LogDir "adapter_advanced_properties_$ts.log"
            $logLines = @()
            $logLines += "================================================================================"
            $logLines += "网卡高级属性全量枚举日志 (适配器: $AdapterName)"
            $logLines += "采集时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            $logLines += "总属性数: $(@($allPropsList).Count) | 相关匹配项: $(@($powerPropsList).Count) | 需关注开启: $attentionEnabledCount | 正常类开启: $normalEnabledCount | 枚举项: $enumCount"
            $logLines += "================================================================================"
            $logLines += ("{0,-35} | {1,-18} | {2,-25} | {3}" -f "DisplayName", "DisplayValue", "RegistryKeyword", "分类标记")
            $logLines += ("-" * 95)
            foreach ($item in $allPropsList) {
                $logLines += ("{0,-35} | {1,-18} | {2,-25} | {3}" -f $item.DisplayName, $item.DisplayValue, $item.RegistryKeyword, $item.StatusText)
            }
            try {
                $logLines | Out-File -FilePath $logPath -Encoding UTF8
            } catch {
                $logPath = $null
            }
        }

        return [PSCustomObject]@{
            Found                  = $true
            AdapterName            = $AdapterName
            Error                  = $null
            TotalPropertiesCount   = @($allPropsList).Count
            PowerRelatedProperties = @($powerPropsList)
            AllProperties          = @($allPropsList)
            PowerRelatedCount      = @($powerPropsList).Count
            EnabledCount           = $attentionEnabledCount + $normalEnabledCount
            AttentionEnabledCount  = $attentionEnabledCount
            NormalEnabledCount     = $normalEnabledCount
            EnumCount              = $enumCount
            LogPath                = $logPath
        }
    } catch {
        return [PSCustomObject]@{
            Found                  = $false
            AdapterName            = $AdapterName
            Error                  = $_.Exception.Message
            TotalPropertiesCount   = 0
            PowerRelatedProperties = @()
            AllProperties          = @()
            PowerRelatedCount      = 0
            EnabledCount           = 0
            AttentionEnabledCount  = 0
            NormalEnabledCount     = 0
            EnumCount              = 0
            LogPath                = $null
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

function Format-SanitizedTimelineText {
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    $res = $Text

    # 1. 脱敏 SSID
    $res = [regex]::Replace($res, '(?i)(?:SSID|Profile Name|网络 SSID)\s*[:=]\s*(\S+)', {
        param($match)
        $val = $match.Groups[1].Value.Trim()
        $safe = if ($val.Length -le 2) { "**" } else { "$($val[0])****$($val[$val.Length - 1])" }
        return "$($match.Value.Substring(0, $match.Value.IndexOf($val)))$safe"
    })

    # 2. 脱敏 MAC / BSSID
    $res = [regex]::Replace($res, '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}', {
        param($match)
        $raw = $match.Value
        $sep = if ($raw.Contains('-')) { '-' } else { ':' }
        $parts = $raw -split '[:-]'
        return "$($parts[0])$sep$($parts[1])$sep**$sep**$sep**$sep$($parts[5])"
    })

    # 3. 脱敏看门狗日志中的代理节点名称
    $res = [regex]::Replace($res, "(?i)(?:best member now|switch on all groups|group)\s*'([^']+)'", {
        param($match)
        return "$($match.Value.Substring(0, $match.Value.IndexOf($match.Groups[1].Value)))[ProxyNode]"
    })

    # 4. 脱敏 http/https URL 为 [URL]
    $res = [regex]::Replace($res, 'https?://\S+', '[URL]')

    return $res
}

function Get-ModernStandbySessions {
    [CmdletBinding()]
    param(
        [int]$HoursBack = -1,
        [string]$LogDir = ""
    )

    $cfg = Get-ToolConfig
    $defaultHours = 24
    if ($null -ne $cfg) {
        if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('TimelineDefaultHoursBack') -and $null -ne $cfg['TimelineDefaultHoursBack']) {
            $defaultHours = [int]$cfg['TimelineDefaultHoursBack']
        } elseif ($cfg.PSObject.Properties['TimelineDefaultHoursBack'] -and $null -ne $cfg.TimelineDefaultHoursBack) {
            $defaultHours = [int]$cfg.TimelineDefaultHoursBack
        }
    }

    $effectiveHours = if ($PSBoundParameters.ContainsKey('HoursBack') -and $HoursBack -ge 0) {
        $HoursBack
    } else {
        $defaultHours
    }

    $now = Get-Date
    $startTime = if ($effectiveHours -le 0) { $now.AddSeconds(1) } else { $now.AddHours(-$effectiveHours) }

    # 读取 Kernel-Power 事件分类映射 (仅基于本机真实枚举出的 ID: 109, 41, 577, 172, 125, 521)
    $enterIds = @(109)
    $exitIds  = @(41, 577)
    $connIds  = @(172)
    $auxIds   = @(125, 521)

    if ($null -ne $cfg) {
        $kpMap = $null
        if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('KernelPowerEventClassifications') -and $null -ne $cfg['KernelPowerEventClassifications']) {
            $kpMap = $cfg['KernelPowerEventClassifications']
        } elseif ($cfg.PSObject.Properties['KernelPowerEventClassifications'] -and $null -ne $cfg.KernelPowerEventClassifications) {
            $kpMap = $cfg.KernelPowerEventClassifications
        }
        if ($null -ne $kpMap) {
            if ($kpMap.Contains('EnterLowPowerEventIds')) { $enterIds = @($kpMap['EnterLowPowerEventIds']) }
            if ($kpMap.Contains('ExitLowPowerEventIds'))  { $exitIds  = @($kpMap['ExitLowPowerEventIds']) }
            if ($kpMap.Contains('StandbyConnectivityEventIds')) { $connIds = @($kpMap['StandbyConnectivityEventIds']) }
            if ($kpMap.Contains('PowerAuxiliaryEventIds')) { $auxIds = @($kpMap['PowerAuxiliaryEventIds']) }
        }
    }

    $powerEvents = [System.Collections.Generic.List[PSCustomObject]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    try {
        if ($effectiveHours -gt 0) {
            $rawEvents = @(Get-WinEvent -FilterHashtable @{
                LogName      = 'System'
                ProviderName = 'Microsoft-Windows-Kernel-Power'
                StartTime    = $startTime
            } -ErrorAction SilentlyContinue)

            foreach ($e in $rawEvents) {
                $eid = [int]$e.Id
                $time = $e.TimeCreated
                $lvl = if ($e.LevelDisplayName) { $e.LevelDisplayName } else { "Information" }
                $msg = if ($e.Message) { $e.Message } else { "" }

                $class = "Other"
                $summary = ""
                if ($enterIds -contains $eid) {
                    $class = "EnterLowPower"
                    $summary = "系统进入低功耗状态/睡眠转换 (Kernel-Power $eid)"
                } elseif ($exitIds -contains $eid) {
                    $class = "ExitLowPower"
                    if ($eid -eq 41) {
                        $summary = "系统从异常关机或掉电中恢复 (Kernel-Power 41)"
                    } elseif ($eid -eq 577) {
                        $summary = "系统准备从活动状态重启/恢复完成 (Kernel-Power 577)"
                    } else {
                        $summary = "系统退出低功耗状态/唤醒恢复 (Kernel-Power $eid)"
                    }
                } elseif ($connIds -contains $eid) {
                    $class = "Connectivity"
                    $state = if ($msg -match '(?i)Connected|连通|连接') { "Connected" } elseif ($msg -match '(?i)Disconnected|离线|断开') { "Disconnected" } else { "StateChanged" }
                    $summary = "现代待机连通性状态变更: $state (Kernel-Power 172)"
                } elseif ($auxIds -contains $eid) {
                    $class = "Auxiliary"
                    if ($eid -eq 125) {
                        $summary = "温区热度状态更新 (Kernel-Power 125)"
                    } elseif ($eid -eq 521) {
                        $summary = "电池充放电状态更新 (Kernel-Power 521)"
                    } else {
                        $summary = "硬件与供电辅助状态 (Kernel-Power $eid)"
                    }
                } else {
                    $firstLine = ($msg -split "`r?`n")[0].Trim()
                    $summary = "Kernel-Power 事件 (ID: $eid): $(if ($firstLine) { $firstLine } else { '无详细信息' })"
                }

                $powerEvents.Add([PSCustomObject]@{
                    Timestamp      = $time
                    TimeCreated    = $time.ToString("yyyy-MM-dd HH:mm:ss")
                    EventId        = $eid
                    Level          = $lvl
                    Classification = $class
                    Summary        = $summary
                })
            }
        }
    } catch {
        $warnings.Add("读取 Kernel-Power 事件异常: $($_.Exception.Message)")
    }

    # 按时间升序构建待机会话
    $sortedPower = @($powerEvents | Sort-Object -Property Timestamp)
    $sessions = [System.Collections.Generic.List[PSCustomObject]]::new()
    $currentEnter = $null

    foreach ($pe in $sortedPower) {
        if ($pe.Classification -eq 'EnterLowPower') {
            $currentEnter = $pe
        } elseif ($pe.Classification -eq 'ExitLowPower' -and $null -ne $currentEnter) {
            $durSeconds = [math]::Round(($pe.Timestamp - $currentEnter.Timestamp).TotalSeconds, 1)
            $sessions.Add([PSCustomObject]@{
                SessionStart = $currentEnter.Timestamp
                SessionEnd   = $pe.Timestamp
                DurationSec  = $durSeconds
                EnterEvent   = $currentEnter
                ExitEvent    = $pe
            })
            $currentEnter = $null
        }
    }

    # 管理员权限下生成 HTML 报告 (powercfg /sleepstudy 与 /systempowerreport)，非管理员优雅跳过
    $sleepstudyPath = $null
    $powerreportPath = $null
    $reportNote = "未生成报告"

    $isAdmin = $false
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]$identity
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $isAdmin = $false
    }

    if ($isAdmin) {
        if (-not [string]::IsNullOrWhiteSpace($LogDir) -and (Test-Path $LogDir)) {
            $ts = (Get-Date).ToString("yyyyMMdd_HHmmss")
            $ssFile = Join-Path $LogDir "sleepstudy_$ts.html"
            $prFile = Join-Path $LogDir "powerreport_$ts.html"

            try {
                & powercfg.exe /sleepstudy /output "$ssFile" *>$null
                if ((Test-Path -LiteralPath $ssFile)) {
                    $sleepstudyPath = $ssFile
                }
            } catch {
                $warnings.Add("生成 sleepstudy 报告异常: $($_.Exception.Message)")
            }

            try {
                & powercfg.exe /systempowerreport /output "$prFile" *>$null
                if ((Test-Path -LiteralPath $prFile)) {
                    $powerreportPath = $prFile
                }
            } catch {
                $warnings.Add("生成 systempowerreport 报告异常: $($_.Exception.Message)")
            }

            $reportNote = "已在管理员权限下生成诊断报告"
        } else {
            $reportNote = "未提供有效日志存储目录，跳过报告生成"
        }
    } else {
        $reportNote = "当前为非管理员会话，跳过生成 HTML 诊断报告 (需管理员权限运行)"
    }

    return [PSCustomObject]@{
        HoursBack            = $effectiveHours
        StartTime            = $startTime.ToString("yyyy-MM-dd HH:mm:ss")
        TotalPowerEvents     = @($sortedPower).Count
        PowerEvents          = @($sortedPower)
        TotalSessions        = @($sessions).Count
        Sessions             = @($sessions)
        IsAdmin              = $isAdmin
        SleepStudyReportPath = $sleepstudyPath
        PowerReportPath      = $powerreportPath
        ReportGenerationNote = $reportNote
        Warnings             = @($warnings)
    }
}

function Get-NetworkEventTimeline {
    [CmdletBinding()]
    param(
        [int]$HoursBack = -1,
        [string]$LogDir = ""
    )

    $cfg = Get-ToolConfig
    $defaultHours = 24
    if ($null -ne $cfg) {
        if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('TimelineDefaultHoursBack') -and $null -ne $cfg['TimelineDefaultHoursBack']) {
            $defaultHours = [int]$cfg['TimelineDefaultHoursBack']
        } elseif ($cfg.PSObject.Properties['TimelineDefaultHoursBack'] -and $null -ne $cfg.TimelineDefaultHoursBack) {
            $defaultHours = [int]$cfg.TimelineDefaultHoursBack
        }
    }

    $effectiveHours = if ($PSBoundParameters.ContainsKey('HoursBack') -and $HoursBack -ge 0) {
        $HoursBack
    } else {
        $defaultHours
    }

    $now = Get-Date
    $startTime = if ($effectiveHours -le 0) { $now.AddSeconds(1) } else { $now.AddHours(-$effectiveHours) }

    $allRecords = [System.Collections.Generic.List[PSCustomObject]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $rssiAbnormalCounts = 0
    $disconnectCounts = 0
    $reconnectFailureCounts = 0
    $keyExchangeTimeoutCounts = 0
    $watchdogActionCounts = 0
    $watchdogActions = [System.Collections.Generic.List[string]]::new()
    $otherEventCounts = @{}

    # 提取分类 ID 映射
    $classMap = @{}
    if ($null -ne $cfg) {
        if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('TimelineEventClassifications') -and $null -ne $cfg['TimelineEventClassifications']) {
            $classMap = $cfg['TimelineEventClassifications']
        } elseif ($cfg.PSObject.Properties['TimelineEventClassifications'] -and $null -ne $cfg.TimelineEventClassifications) {
            $classMap = $cfg.TimelineEventClassifications
        }
    }

    $disconnectIds = if ($classMap.Contains('DisconnectEventIds')) { $classMap['DisconnectEventIds'] } else { @(8003, 11004) }
    $failureIds    = if ($classMap.Contains('ConnectionFailureEventIds')) { $classMap['ConnectionFailureEventIds'] } else { @(8002) }
    $timeoutIds    = if ($classMap.Contains('KeyExchangeTimeoutEventIds')) { $classMap['KeyExchangeTimeoutEventIds'] } else { @(11006) }
    $assocIds      = if ($classMap.Contains('AssociationEventIds')) { $classMap['AssociationEventIds'] } else { @(8000, 8001, 11000, 11001, 11005, 11010) }
    $abnormalRssi  = if ($classMap.Contains('AbnormalRssiValues')) { $classMap['AbnormalRssiValues'] } else { @(255) }

    # --------------------------------------------------------------------------
    # 1. 来源一：WLAN 事件 (Operational 日志)
    # --------------------------------------------------------------------------
    try {
        if ($effectiveHours -gt 0) {
            $wlanRaw = @(Get-WinEvent -FilterHashtable @{
                LogName   = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
                StartTime = $startTime
            } -ErrorAction SilentlyContinue)

            foreach ($e in $wlanRaw) {
                $eid = [int]$e.Id
                $time = $e.TimeCreated
                $lvl = if ($e.LevelDisplayName) { $e.LevelDisplayName } else { "Information" }
                $msg = if ($e.Message) { $e.Message } else { "" }

                $summary = ""
                if ($eid -eq 8002) {
                    $reconnectFailureCounts++
                    $rssiVal = $null
                    if ($msg -match '(?i)RSSI\s*:\s*(-?\d+)') {
                        $rssiVal = [int]$matches[1]
                        if ($abnormalRssi -contains $rssiVal) {
                            $rssiAbnormalCounts++
                        }
                    }
                    $failReason = if ($msg -match '(?i)(?:Failure Reason|失败原因)\s*:\s*(.+)') { $matches[1].Trim() } else { "连接失败" }
                    $summary = "无线连接失败 [原因: $failReason, RSSI: $(if ($rssiVal -ne $null) { $rssiVal } else { '未知' })]"
                } elseif ($eid -eq 8003) {
                    $disconnectCounts++
                    $reason = if ($msg -match '(?i)(?:Reason|原因)\s*:\s*(.+)') { $matches[1].Trim() } else { "网络被驱动程序断开" }
                    $summary = "无线网络被断开 [原因: $reason]"
                } elseif ($eid -eq 11004) {
                    $disconnectCounts++
                    $summary = "无线安全已停止 (Security stopped)"
                } elseif ($eid -eq 11006) {
                    $keyExchangeTimeoutCounts++
                    $summary = "动态密钥交换在配置的时间范围内未能成功"
                } elseif ($eid -eq 8000) {
                    $summary = "发起无线网络连接 (Association started)"
                } elseif ($eid -eq 8001) {
                    $summary = "成功连接到无线网络 (Connected)"
                } elseif ($eid -eq 11000) {
                    $summary = "无线网络关联开始"
                } elseif ($eid -eq 11001) {
                    $summary = "无线网络关联成功"
                } elseif ($eid -eq 11005) {
                    $summary = "无线安全握手成功 (Security succeeded)"
                } elseif ($eid -eq 11010) {
                    $summary = "无线安全开始 (Security started)"
                } else {
                    $firstLine = ($msg -split "`r?`n")[0].Trim()
                    $summary = if ($firstLine) { $firstLine } else { "WLAN 事件" }
                    $k = "WLAN:$eid"
                    if (-not $otherEventCounts.ContainsKey($k)) { $otherEventCounts[$k] = 0 }
                    $otherEventCounts[$k]++
                }

                $sanitizedSummary = Format-SanitizedTimelineText -Text $summary

                $allRecords.Add([PSCustomObject]@{
                    Timestamp   = $time
                    TimeCreated = $time.ToString("yyyy-MM-dd HH:mm:ss")
                    Source      = "WLAN"
                    EventId     = $eid
                    Level       = $lvl
                    Summary     = $sanitizedSummary
                })
            }
        }
    } catch {
        $warnings.Add("WLAN 事件读取提示: $($_.Exception.Message)")
    }

    # --------------------------------------------------------------------------
    # 2. 来源二：System 事件 (按网络相关 Provider 过滤)
    # --------------------------------------------------------------------------
    try {
        if ($effectiveHours -gt 0) {
            $sysProviders = @("mtkwlex", "Microsoft-Windows-WLAN-AutoConfig", "Microsoft-Windows-DNS-Client", "Tcpip", "Microsoft-Windows-Dhcp-Client", "Microsoft-Windows-DHCPv6-Client", "Service Control Manager")
            if ($null -ne $cfg) {
                if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('TimelineSystemProviders') -and $null -ne $cfg['TimelineSystemProviders']) {
                    $sysProviders = $cfg['TimelineSystemProviders']
                } elseif ($cfg.PSObject.Properties['TimelineSystemProviders'] -and $null -ne $cfg.TimelineSystemProviders) {
                    $sysProviders = $cfg.TimelineSystemProviders
                }
            }

            $sysRaw = @(Get-WinEvent -FilterHashtable @{
                LogName   = 'System'
                StartTime = $startTime
            } -ErrorAction SilentlyContinue | Where-Object { $sysProviders -contains $_.ProviderName })

            foreach ($e in $sysRaw) {
                $eid = [int]$e.Id
                $time = $e.TimeCreated
                $lvl = if ($e.LevelDisplayName) { $e.LevelDisplayName } else { "Information" }
                $msg = if ($e.Message) { $e.Message } else { "" }
                $prov = $e.ProviderName

                $summary = ""
                if ($prov -eq 'Service Control Manager') {
                    if ($eid -eq 7036) {
                        $summary = "服务状态变更: $(($msg -split "`r?`n")[0])"
                    } elseif ($eid -eq 7040) {
                        $summary = "服务启动类型变更: $(($msg -split "`r?`n")[0])"
                    } elseif ($eid -eq 7045) {
                        $svcName = if ($msg -match '(?i)Service Name:\s*(\S+)') { $matches[1] } else { "未知服务" }
                        $summary = "系统安装了新服务/驱动: $svcName"
                    } else {
                        $summary = "SCM 服务事件: $(($msg -split "`r?`n")[0])"
                    }
                } elseif ($prov -eq 'Microsoft-Windows-DNS-Client' -and $eid -eq 1014) {
                    $domain = if ($msg -match '(?i)name\s+(\S+)\s+timed out') { $matches[1] } else { "域名解析" }
                    $summary = "DNS 解析超时告警: $domain"
                } elseif ($prov -eq 'Tcpip' -and $eid -eq 4207) {
                    $summary = "TCP/IP 接口绑定提供程序失败 (ID 4207)"
                } elseif ($prov -eq 'mtkwlex') {
                    $summary = "MT7922 无线驱动底层事件 (ID: $eid)"
                } else {
                    $firstLine = ($msg -split "`r?`n")[0].Trim()
                    $summary = "[$prov] $(if ($firstLine) { $firstLine } else { 'System 事件' })"
                }

                $k = "System:$eid"
                if ($eid -ne 7036 -and $eid -ne 7040 -and $eid -ne 7045 -and $eid -ne 1014 -and $eid -ne 4207) {
                    if (-not $otherEventCounts.ContainsKey($k)) { $otherEventCounts[$k] = 0 }
                    $otherEventCounts[$k]++
                }

                $sanitizedSummary = Format-SanitizedTimelineText -Text $summary

                $allRecords.Add([PSCustomObject]@{
                    Timestamp   = $time
                    TimeCreated = $time.ToString("yyyy-MM-dd HH:mm:ss")
                    Source      = "System"
                    EventId     = $eid
                    Level       = $lvl
                    Summary     = $sanitizedSummary
                })
            }
        }
    } catch {
        $warnings.Add("System 日志读取提示: $($_.Exception.Message)")
    }

    # --------------------------------------------------------------------------
    # 3. 来源三：看门狗日志 (可选，只读 Select-String 过滤)
    # --------------------------------------------------------------------------
    $watchdogLogPath = ""
    if ($null -ne $cfg) {
        if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('WatchdogLogPath') -and $null -ne $cfg['WatchdogLogPath']) {
            $watchdogLogPath = [string]$cfg['WatchdogLogPath']
        } elseif ($cfg.PSObject.Properties['WatchdogLogPath'] -and $null -ne $cfg.WatchdogLogPath) {
            $watchdogLogPath = [string]$cfg.WatchdogLogPath
        }
    }

    if ([string]::IsNullOrWhiteSpace($watchdogLogPath) -or -not (Test-Path -LiteralPath $watchdogLogPath)) {
        $warnings.Add("未找到本机看门狗日志，已跳过该来源")
    } else {
        try {
            if ($effectiveHours -gt 0) {
                # 严格遵守约束 G: 仅用 Select-String 过滤关键字行
                $matchedLines = @(Select-String -Path $watchdogLogPath -Pattern '\[(ACTION|WARN|ERROR|DIAG)\]' -ErrorAction SilentlyContinue)
                foreach ($m in $matchedLines) {
                    $line = $m.Line
                    if ($line -match '^\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\]\s+\[(ACTION|WARN|ERROR|DIAG)\]\s+(.+)$') {
                        $logTimeStr = $matches[1]
                        $logLvl = $matches[2]
                        $logBody = $matches[3]

                        $parsedTime = [datetime]::ParseExact($logTimeStr, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                        if ($parsedTime -ge $startTime) {
                            if ($logLvl -eq 'ACTION') {
                                $watchdogActionCounts++
                                $actName = ($logBody -split '\(')[0].Trim()
                                if ($actName.Length -gt 50) { $actName = $actName.Substring(0, 50) }
                                $watchdogActions.Add($actName)
                            }

                            $sanitizedBody = Format-SanitizedTimelineText -Text $logBody

                            $allRecords.Add([PSCustomObject]@{
                                Timestamp   = $parsedTime
                                TimeCreated = $logTimeStr
                                Source      = "Watchdog"
                                EventId     = $null
                                Level       = $logLvl
                                Summary     = $sanitizedBody
                            })
                        }
                    }
                }
            }
        } catch {
            $warnings.Add("读取看门狗日志异常: $($_.Exception.Message)")
        }
    }

    # --------------------------------------------------------------------------
    # 4. 来源四：现代待机会话与电源事件 (Kernel-Power 与 powercfg 关联)
    # --------------------------------------------------------------------------
    $standbyData = $null
    $standbyCorrelation = $null
    try {
        $standbyData = Get-ModernStandbySessions -HoursBack $effectiveHours -LogDir $LogDir
        if ($standbyData -and @($standbyData.PowerEvents).Count -gt 0) {
            foreach ($pe in $standbyData.PowerEvents) {
                $allRecords.Add([PSCustomObject]@{
                    Timestamp   = $pe.Timestamp
                    TimeCreated = $pe.TimeCreated
                    Source      = "Power"
                    EventId     = $pe.EventId
                    Level       = $pe.Level
                    Summary     = (Format-SanitizedTimelineText -Text $pe.Summary)
                })
            }
        }
        if ($standbyData -and @($standbyData.Warnings).Count -gt 0) {
            foreach ($sw in $standbyData.Warnings) {
                $warnings.Add($sw)
            }
        }

        # 关联分析判定：计算 WLAN 断开事件与待机会话的时间关系
        $wakeGraceSec = 30
        $proximitySec = 60
        if ($null -ne $cfg) {
            if ($cfg -is [System.Collections.IDictionary]) {
                if ($cfg.Contains('StandbyWakeGracePeriodSeconds') -and $null -ne $cfg['StandbyWakeGracePeriodSeconds']) {
                    $wakeGraceSec = [int]$cfg['StandbyWakeGracePeriodSeconds']
                }
                if ($cfg.Contains('StandbySessionProximitySeconds') -and $null -ne $cfg['StandbySessionProximitySeconds']) {
                    $proximitySec = [int]$cfg['StandbySessionProximitySeconds']
                }
            } elseif ($cfg.PSObject.Properties['StandbyWakeGracePeriodSeconds'] -and $null -ne $cfg.StandbyWakeGracePeriodSeconds) {
                $wakeGraceSec = [int]$cfg.StandbyWakeGracePeriodSeconds
                if ($cfg.PSObject.Properties['StandbySessionProximitySeconds'] -and $null -ne $cfg.StandbySessionProximitySeconds) {
                    $proximitySec = [int]$cfg.StandbySessionProximitySeconds
                }
            }
        }

        $inSessionCount = 0
        $postWakeCount = 0
        $preSleepCount = 0
        $awakeCount = 0

        $exitTimes = @()
        $enterTimes = @()
        if ($standbyData -and @($standbyData.PowerEvents).Count -gt 0) {
            $exitTimes = @($standbyData.PowerEvents | Where-Object { $_.Classification -eq 'ExitLowPower' } | ForEach-Object { $_.Timestamp })
            $enterTimes = @($standbyData.PowerEvents | Where-Object { $_.Classification -eq 'EnterLowPower' } | ForEach-Object { $_.Timestamp })
        }

        $wlanDisconnectRecords = @($allRecords | Where-Object { $_.Source -eq 'WLAN' -and $disconnectIds -contains $_.EventId })

        foreach ($rec in $wlanDisconnectRecords) {
            $tDisc = $rec.Timestamp
            $matched = $false

            # 判定是否处于会话期内
            if ($standbyData -and @($standbyData.Sessions).Count -gt 0) {
                foreach ($s in $standbyData.Sessions) {
                    if ($tDisc -ge $s.SessionStart -and $tDisc -le $s.SessionEnd) {
                        $inSessionCount++
                        $matched = $true
                        break
                    }
                }
            }
            if ($matched) { continue }

            # 判定是否在退出唤醒后 N 秒内
            foreach ($tEx in $exitTimes) {
                $diff = ($tDisc - $tEx).TotalSeconds
                if ($diff -ge 0 -and $diff -le $wakeGraceSec) {
                    $postWakeCount++
                    $matched = $true
                    break
                }
            }
            if ($matched) { continue }

            # 判定是否在进入低功耗前夕 N 秒内
            foreach ($tEn in $enterTimes) {
                $diff = ($tEn - $tDisc).TotalSeconds
                if ($diff -ge 0 -and $diff -le $proximitySec) {
                    $preSleepCount++
                    $matched = $true
                    break
                }
            }
            if ($matched) { continue }

            $awakeCount++
        }

        $standbyCorrelation = [PSCustomObject]@{
            TotalDisconnects           = $disconnectCounts
            InSessionDisconnects       = $inSessionCount
            PostWakeDisconnects        = $postWakeCount
            PreSleepDisconnects        = $preSleepCount
            AwakeDisconnects           = $awakeCount
            TotalSessions              = if ($standbyData) { $standbyData.TotalSessions } else { 0 }
            TotalPowerEvents           = if ($standbyData) { $standbyData.TotalPowerEvents } else { 0 }
            WakeGracePeriodSeconds     = $wakeGraceSec
            ProximitySeconds           = $proximitySec
            Disclaimer                 = "以上仅为时间相关性，不构成因果结论。"
        }
    } catch {
        $warnings.Add("现代待机与电源关联分析异常: $($_.Exception.Message)")
    }

    # 按时间戳升序排序
    $sorted = @($allRecords | Sort-Object -Property Timestamp)

    return [PSCustomObject]@{
        HoursBack                  = $effectiveHours
        StartTime                  = $startTime.ToString("yyyy-MM-dd HH:mm:ss")
        TotalRecords               = @($sorted).Count
        Records                    = $sorted
        DisconnectCount            = $disconnectCounts
        ReconnectFailureCount      = $reconnectFailureCounts
        KeyExchangeTimeoutCount    = $keyExchangeTimeoutCounts
        RssiAbnormalCount          = $rssiAbnormalCounts
        WatchdogActionCount        = $watchdogActionCounts
        WatchdogActions            = @($watchdogActions)
        OtherEventCounts           = $otherEventCounts
        ModernStandby              = $standbyData
        StandbyCorrelation         = $standbyCorrelation
        Warnings                   = @($warnings)
        Disclaimer                 = "以上仅为时间相关性，不构成因果结论。"
    }
}


Export-ModuleMember -Function @(
    'Get-ToolConfig',
    'Get-DefaultRouteInfo',
    'Get-IPv6Status',
    'Get-ActivePhysicalAdapter',
    'Get-AdapterPowerManagementStatus',
    'Get-SystemSleepCapability',
    'Get-AdapterAdvancedPowerProperties',
    'Get-WlanLinkQuality',
    'Get-AdapterIpDetails',
    'Get-DhcpLeaseInfo',
    'Get-NcsiStatus',
    'Get-ProxyStatus',
    'Get-NetworkServiceStatus',
    'Get-WlanDiagnostics',
    'Get-LocalWatchdogStatus',
    'Get-NetworkEventTimeline',
    'Get-ModernStandbySessions'
)

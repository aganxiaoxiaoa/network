#Requires -Version 5.1
# ==============================================================================
# SafeRecoveryObservation.psm1
# 独立安全恢复模块 - 只读观察层 (Observation Layer)
#
# 【本文件永久红线】严禁出现任何网络状态变更指令：
#   - 严禁 netsh wlan connect / disconnect / delete profile / set / add / export
#   - 严禁 ipconfig /renew / /release / /flushdns
#   - 严禁 netsh winsock reset / netsh int ip reset / netcfg -d
#   - 严禁修改注册表、系统代理、WinHTTP 代理、Clash / ProxyBridge 进程
#   - 严禁 Disable-NetAdapter / Enable-NetAdapter / Restart-NetAdapter
#   - 严禁修改服务、计划任务、看门狗 (仅允许读取其状态)
#   - 严禁 netsh wlan show profile key=clear (绝不读取明文密钥)
#
# 本层只负责：读取配置、识别唯一无线网卡、读取链路与 DHCP 状态、判定健康度、写 U 盘日志。
# ==============================================================================

Set-StrictMode -Version 2.0

# ------------------------------------------------------------------------------
# 严格模式安全属性读取 (CIM 对象可能缺少属性，直接访问会在 StrictMode 2.0 下抛错)
# ------------------------------------------------------------------------------
function Get-SafeRecoveryPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# ------------------------------------------------------------------------------
# 配置加载与强校验
# ------------------------------------------------------------------------------
function Get-SafeRecoveryConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AppDir)

    $configPath = Join-Path $AppDir 'SafeRecovery.Config.psd1'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "安全恢复配置文件缺失: $configPath"
    }

    $config = Import-PowerShellDataFile -LiteralPath $configPath
    if ($null -eq $config -or $config -isnot [hashtable]) {
        throw "安全恢复配置文件格式无效: $configPath"
    }

    Assert-SafeRecoveryConfig -Config $config
    return $config
}

function Assert-SafeRecoveryConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    $allowed = @($Config['AllowedProfiles'])
    if ($allowed.Count -eq 0) {
        throw '配置无效: AllowedProfiles 不能为空，安全恢复必须有明确的配置文件白名单。'
    }
    foreach ($name in $allowed) {
        if ([string]::IsNullOrWhiteSpace([string]$name)) {
            throw '配置无效: AllowedProfiles 中存在空白项。'
        }
        if ([string]$name -notmatch '^[A-Za-z0-9_-]{1,32}$') {
            throw "配置无效: 配置文件名称 '$name' 含非受控字符，拒绝加载。"
        }
    }

    foreach ($key in @('PrimaryProfile', 'FallbackProfile')) {
        $value = [string]$Config[$key]
        if ($allowed -notcontains $value) {
            throw "配置无效: $key = '$value' 不在 AllowedProfiles 白名单内。"
        }
    }

    $numericLimits = @{
        'ConnectTimeoutSeconds'    = @(5, 300)
        'DhcpAutoWaitSeconds'      = @(0, 120)
        'DhcpWaitSeconds'          = @(5, 300)
        'PollIntervalMilliseconds' = @(200, 5000)
        'GatewayPingCount'         = @(0, 4)
    }
    foreach ($key in $numericLimits.Keys) {
        $raw = $Config[$key]
        if ($null -eq $raw -or "$raw" -notmatch '^\d+$') {
            throw "配置无效: $key 必须是非负整数。"
        }
        $value = [int]$raw
        $range = $numericLimits[$key]
        if ($value -lt $range[0] -or $value -gt $range[1]) {
            throw "配置无效: $key = $value 超出允许范围 $($range[0])-$($range[1])。"
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config['ConfirmationToken'])) {
        throw '配置无效: ConfirmationToken 不能为空，必须保留人工确认环节。'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Config['LogSubDirectory'])) {
        throw '配置无效: LogSubDirectory 不能为空。'
    }
}

function Get-SafeRecoveryProfileOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $false)][string]$PreferredProfile
    )

    $allowed = @($Config['AllowedProfiles'])
    $order = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($PreferredProfile)) {
        if ($allowed -notcontains $PreferredProfile) {
            throw "拒绝执行: 配置文件 '$PreferredProfile' 不在白名单 ($($allowed -join ', ')) 内。"
        }
        $order.Add($PreferredProfile)
    } else {
        $order.Add([string]$Config['PrimaryProfile'])
        $fallback = [string]$Config['FallbackProfile']
        if (-not $order.Contains($fallback)) { $order.Add($fallback) }
    }

    foreach ($name in $allowed) {
        if (-not $order.Contains([string]$name)) { $order.Add([string]$name) }
    }
    return $order.ToArray()
}

# ------------------------------------------------------------------------------
# 权限与看门狗状态 (只读)
# ------------------------------------------------------------------------------
function Test-SafeRecoveryAdmin {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SafeRecoveryWatchdogStatus {
    [CmdletBinding()]
    param([string]$TaskName = 'NetworkRecoveryWatchdog')

    $taskState = 'NotFound'
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            $state = Get-SafeRecoveryPropertyValue -InputObject $task -Name 'State'
            if ($null -ne $state) { $taskState = [string]$state }
        }
    } catch {
        $taskState = 'QueryFailed'
    }

    $processId = $null
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            $commandLine = [string](Get-SafeRecoveryPropertyValue -InputObject $process -Name 'CommandLine')
            if ($commandLine -like '*auto_network_recovery.ps1*') {
                $processId = Get-SafeRecoveryPropertyValue -InputObject $process -Name 'ProcessId'
                break
            }
        }
    } catch {
        $processId = $null
    }

    return [pscustomobject]@{
        TaskName  = $TaskName
        TaskState = $taskState
        ProcessId = $processId
        IsActive  = ($taskState -eq 'Running' -or $null -ne $processId)
    }
}

# ------------------------------------------------------------------------------
# 只读 netsh 调用 (硬性限制为 show 查询)
# ------------------------------------------------------------------------------
function Invoke-SafeRecoveryReadOnlyNetsh {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)

    if ($ArgumentList -notcontains 'show') {
        throw '拒绝执行: 只读 netsh 调用必须包含 show 动词。'
    }
    foreach ($forbidden in @('connect', 'disconnect', 'delete', 'set', 'add', 'reset', 'export', 'import', 'start', 'stop')) {
        if ($ArgumentList -contains $forbidden) {
            throw "拒绝执行: 只读 netsh 调用禁止包含 '$forbidden'。"
        }
    }
    foreach ($argument in $ArgumentList) {
        if ([string]$argument -match 'key\s*=\s*clear') {
            throw '拒绝执行: 严禁读取明文 Wi-Fi 密钥。'
        }
    }

    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    if (-not (Test-Path -LiteralPath $netsh)) { $netsh = 'netsh.exe' }

    $global:LASTEXITCODE = 0
    $output = & $netsh @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        Command  = "netsh $($ArgumentList -join ' ')"
        ExitCode = $exitCode
        Output   = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
    }
}

function ConvertFrom-SafeRecoveryProfileList {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Output)

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Output -split "`r?`n")) {
        $separatorIndex = $line.IndexOf(':')
        if ($separatorIndex -lt 1) { continue }

        $label = $line.Substring(0, $separatorIndex)
        $value = $line.Substring($separatorIndex + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        # 兼容英文 / 简体中文 / 繁体中文 netsh 输出标签，避免依赖单一语言环境
        if ($label -notmatch '(?i)profile|配置文件|設定檔') { continue }

        if (-not $names.Contains($value)) { $names.Add($value) }
    }
    return $names.ToArray()
}

function Get-SafeRecoveryInstalledProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][string]$InterfaceName)

    $arguments = @('wlan', 'show', 'profiles')
    if (-not [string]::IsNullOrWhiteSpace($InterfaceName)) {
        $arguments += "interface=$InterfaceName"
    }

    $result = Invoke-SafeRecoveryReadOnlyNetsh -ArgumentList $arguments
    if ($result.ExitCode -ne 0) {
        throw "读取已保存的 Wi-Fi 配置文件列表失败 (退出码 $($result.ExitCode)): $($result.Output)"
    }
    return ConvertFrom-SafeRecoveryProfileList -Output $result.Output
}

# ------------------------------------------------------------------------------
# 无线网卡识别 (零个或多个候选时必须中止，绝不猜测)
# ------------------------------------------------------------------------------
function Test-SafeRecoveryIsWirelessAdapter {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)]$Adapter)

    if ($null -eq $Adapter) { return $false }

    if ((Get-SafeRecoveryPropertyValue -InputObject $Adapter -Name 'Virtual') -eq $true) { return $false }
    if ((Get-SafeRecoveryPropertyValue -InputObject $Adapter -Name 'HardwareInterface') -eq $false) { return $false }

    $interfaceType = Get-SafeRecoveryPropertyValue -InputObject $Adapter -Name 'InterfaceType'
    if ($null -ne $interfaceType -and "$interfaceType" -match '^\d+$' -and [int]$interfaceType -eq 71) {
        return $true
    }

    foreach ($propertyName in @('PhysicalMediaType', 'MediaType')) {
        $value = Get-SafeRecoveryPropertyValue -InputObject $Adapter -Name $propertyName
        if ($value -is [string] -and $value -match '802\.11') { return $true }
    }
    return $false
}

function Select-SafeRecoveryWlanCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Adapter,
        [Parameter(Mandatory = $false)][string]$ExpectedInterfaceGuid
    )

    $candidates = @($Adapter | Where-Object { Test-SafeRecoveryIsWirelessAdapter -Adapter $_ })

    if (-not [string]::IsNullOrWhiteSpace($ExpectedInterfaceGuid)) {
        $normalized = $ExpectedInterfaceGuid.Trim().Trim('{', '}')
        $candidates = @($candidates | Where-Object {
            $guid = [string](Get-SafeRecoveryPropertyValue -InputObject $_ -Name 'InterfaceGuid')
            $guid.Trim().Trim('{', '}') -eq $normalized
        })
    }
    return $candidates
}

function Resolve-SafeRecoveryWlanAdapter {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][string]$ExpectedInterfaceGuid)

    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop)
    $candidates = @(Select-SafeRecoveryWlanCandidate -Adapter $adapters -ExpectedInterfaceGuid $ExpectedInterfaceGuid)

    if ($candidates.Count -eq 0) {
        throw '未能识别出物理无线网卡 (802.11)。为避免误操作有线或虚拟网卡，安全恢复已中止。'
    }
    if ($candidates.Count -gt 1) {
        $list = ($candidates | ForEach-Object {
            "$(Get-SafeRecoveryPropertyValue -InputObject $_ -Name 'Name') [$(Get-SafeRecoveryPropertyValue -InputObject $_ -Name 'InterfaceGuid')]"
        }) -join '; '
        throw "检测到多个无线网卡候选，存在歧义，安全恢复已中止。请使用 -InterfaceGuid 明确指定其中之一: $list"
    }

    $adapter = $candidates[0]
    return [pscustomobject]@{
        Name                 = [string](Get-SafeRecoveryPropertyValue -InputObject $adapter -Name 'Name')
        InterfaceIndex       = [int](Get-SafeRecoveryPropertyValue -InputObject $adapter -Name 'InterfaceIndex')
        InterfaceGuid        = [string](Get-SafeRecoveryPropertyValue -InputObject $adapter -Name 'InterfaceGuid')
        InterfaceDescription = [string](Get-SafeRecoveryPropertyValue -InputObject $adapter -Name 'InterfaceDescription')
        Status               = [string](Get-SafeRecoveryPropertyValue -InputObject $adapter -Name 'Status')
        MediaConnectionState = [string](Get-SafeRecoveryPropertyValue -InputObject $adapter -Name 'MediaConnectionState')
    }
}

# ------------------------------------------------------------------------------
# 链路 / IP / DHCP 状态读取
# ------------------------------------------------------------------------------
function Test-SafeRecoveryIPv4Usable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][string]$IPAddress)

    if ([string]::IsNullOrWhiteSpace($IPAddress)) { return $false }
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($IPAddress.Trim(), [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }

    $text = $parsed.ToString()
    if ($text -eq '0.0.0.0') { return $false }
    if ($text -like '169.254.*') { return $false }   # APIPA 表示 DHCP 未成功
    if ($text -like '127.*') { return $false }
    return $true
}

function Format-SafeRecoveryProfileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$AllowedProfile
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return '(none)' }
    if ($AllowedProfile -contains $Name) { return $Name }
    # 白名单以外的 SSID 一律脱敏，避免日志泄露其他无关网络名称
    if ($Name.Length -le 3) { return '***' }
    return $Name.Substring(0, 2) + '***' + $Name.Substring($Name.Length - 1, 1)
}

function Get-SafeRecoveryInterfaceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InterfaceGuid,
        [Parameter(Mandatory = $false)][int]$GatewayPingCount = 0
    )

    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {
        ([string](Get-SafeRecoveryPropertyValue -InputObject $_ -Name 'InterfaceGuid')).Trim().Trim('{', '}') -eq $InterfaceGuid.Trim().Trim('{', '}')
    })
    if ($adapters.Count -ne 1) {
        throw "无法按 GUID 唯一定位无线网卡 ($InterfaceGuid)，匹配数量: $($adapters.Count)。安全恢复已中止。"
    }
    $adapter = $adapters[0]
    if (-not (Test-SafeRecoveryIsWirelessAdapter -Adapter $adapter)) {
        throw '目标网卡已不再被识别为物理无线网卡，安全恢复已中止。'
    }

    $interfaceIndex = [int](Get-SafeRecoveryPropertyValue -InputObject $adapter -Name 'InterfaceIndex')

    $dhcpEnabled = $null
    try {
        $ipInterface = Get-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop
        $dhcp = Get-SafeRecoveryPropertyValue -InputObject $ipInterface -Name 'Dhcp'
        if ($null -ne $dhcp) { $dhcpEnabled = ([string]$dhcp -eq 'Enabled') }
    } catch {
        $dhcpEnabled = $null
    }

    $ipv4Address = $null
    $prefixOrigin = $null
    try {
        $addresses = @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
            Sort-Object -Property @{ Expression = { [string](Get-SafeRecoveryPropertyValue -InputObject $_ -Name 'IPAddress') -like '169.254.*' } })
        if ($addresses.Count -gt 0) {
            $ipv4Address = [string](Get-SafeRecoveryPropertyValue -InputObject $addresses[0] -Name 'IPAddress')
            $prefixOrigin = [string](Get-SafeRecoveryPropertyValue -InputObject $addresses[0] -Name 'PrefixOrigin')
        }
    } catch {
        $ipv4Address = $null
    }

    $connectedProfile = $null
    $ipv4Connectivity = $null
    try {
        $connectionProfile = Get-NetConnectionProfile -InterfaceIndex $interfaceIndex -ErrorAction SilentlyContinue
        if ($null -ne $connectionProfile) {
            $connectedProfile = [string](Get-SafeRecoveryPropertyValue -InputObject $connectionProfile -Name 'Name')
            $ipv4Connectivity = [string](Get-SafeRecoveryPropertyValue -InputObject $connectionProfile -Name 'IPv4Connectivity')
        }
    } catch {
        $connectedProfile = $null
    }

    $gateway = $null
    try {
        $routes = @(Get-NetRoute -InterfaceIndex $interfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object -Property @{ Expression = { [int](Get-SafeRecoveryPropertyValue -InputObject $_ -Name 'RouteMetric') } })
        if ($routes.Count -gt 0) {
            $gateway = [string](Get-SafeRecoveryPropertyValue -InputObject $routes[0] -Name 'NextHop')
        }
    } catch {
        $gateway = $null
    }

    $gatewayPing = 'SKIPPED'
    if ($GatewayPingCount -gt 0 -and -not [string]::IsNullOrWhiteSpace($gateway)) {
        try {
            $reachable = Test-Connection -ComputerName $gateway -Count $GatewayPingCount -Quiet -ErrorAction SilentlyContinue
            $gatewayPing = if ($reachable) { 'REACHABLE' } else { 'NO-REPLY' }
        } catch {
            $gatewayPing = 'ERROR'
        }
    }

    return [pscustomobject]@{
        Timestamp            = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        AdapterName          = [string](Get-SafeRecoveryPropertyValue -InputObject $adapter -Name 'Name')
        InterfaceIndex       = $interfaceIndex
        InterfaceGuid        = [string](Get-SafeRecoveryPropertyValue -InputObject $adapter -Name 'InterfaceGuid')
        Status               = [string](Get-SafeRecoveryPropertyValue -InputObject $adapter -Name 'Status')
        MediaConnectionState = [string](Get-SafeRecoveryPropertyValue -InputObject $adapter -Name 'MediaConnectionState')
        ConnectedProfile     = $connectedProfile
        IPv4Connectivity     = $ipv4Connectivity
        DhcpEnabled          = $dhcpEnabled
        IPv4Address          = $ipv4Address
        PrefixOrigin         = $prefixOrigin
        DefaultGateway       = $gateway
        HasDefaultRoute      = (-not [string]::IsNullOrWhiteSpace($gateway))
        GatewayPing          = $gatewayPing
    }
}

function Test-SafeRecoveryConnectionHealthy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$ExpectedProfile
    )

    $reasons = New-Object System.Collections.Generic.List[string]

    $mediaState = [string](Get-SafeRecoveryPropertyValue -InputObject $State -Name 'MediaConnectionState')
    if ($mediaState -ne 'Connected') {
        $reasons.Add("无线介质状态不是 Connected (当前: $mediaState)")
    }

    $connectedProfile = [string](Get-SafeRecoveryPropertyValue -InputObject $State -Name 'ConnectedProfile')
    if ($connectedProfile -ne $ExpectedProfile) {
        $reasons.Add("当前网络不是目标配置文件 $ExpectedProfile")
    }

    $ipv4 = [string](Get-SafeRecoveryPropertyValue -InputObject $State -Name 'IPv4Address')
    if (-not (Test-SafeRecoveryIPv4Usable -IPAddress $ipv4)) {
        $reasons.Add('没有取得可用的 IPv4 地址 (缺失或为 169.254.x.x)')
    }

    if ((Get-SafeRecoveryPropertyValue -InputObject $State -Name 'HasDefaultRoute') -ne $true) {
        $reasons.Add('该无线接口上不存在默认路由')
    }

    return [pscustomobject]@{
        IsHealthy = ($reasons.Count -eq 0)
        Reasons   = $reasons.ToArray()
    }
}

# ------------------------------------------------------------------------------
# U 盘内日志 (不记录密钥、BSSID、配置文件 XML 与公网地址)
# ------------------------------------------------------------------------------
function New-SafeRecoveryLogSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$LogSubDirectory
    )

    $directory = Join-Path $ToolRoot $LogSubDirectory
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return (Join-Path $directory ("safe-recovery-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + ".log"))
}

function Write-SafeRecoveryLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][string]$LogPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [Parameter(Mandatory = $false)][ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [switch]$NoConsole
    )

    if (-not $NoConsole) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }

    $line = "[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Message
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Host "[警告] 写入恢复日志失败: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-SafeRecoveryStateSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][string]$LogPath,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$AllowedProfile
    )

    $profileText = Format-SafeRecoveryProfileName -Name ([string](Get-SafeRecoveryPropertyValue -InputObject $State -Name 'ConnectedProfile')) -AllowedProfile $AllowedProfile
    $fields = @(
        "Adapter=$(Get-SafeRecoveryPropertyValue -InputObject $State -Name 'AdapterName')",
        "IfIndex=$(Get-SafeRecoveryPropertyValue -InputObject $State -Name 'InterfaceIndex')",
        "Status=$(Get-SafeRecoveryPropertyValue -InputObject $State -Name 'Status')",
        "Media=$(Get-SafeRecoveryPropertyValue -InputObject $State -Name 'MediaConnectionState')",
        "Profile=$profileText",
        "IPv4=$(Get-SafeRecoveryPropertyValue -InputObject $State -Name 'IPv4Address')",
        "PrefixOrigin=$(Get-SafeRecoveryPropertyValue -InputObject $State -Name 'PrefixOrigin')",
        "Dhcp=$(Get-SafeRecoveryPropertyValue -InputObject $State -Name 'DhcpEnabled')",
        "Gateway=$(Get-SafeRecoveryPropertyValue -InputObject $State -Name 'DefaultGateway')",
        "GatewayPing=$(Get-SafeRecoveryPropertyValue -InputObject $State -Name 'GatewayPing')",
        "IPv4Connectivity=$(Get-SafeRecoveryPropertyValue -InputObject $State -Name 'IPv4Connectivity')"
    )
    Write-SafeRecoveryLog -LogPath $LogPath -Message ("[$Label] " + ($fields -join ' | ')) -ForegroundColor Gray
}

Export-ModuleMember -Function @(
    'Get-SafeRecoveryPropertyValue',
    'Get-SafeRecoveryConfig',
    'Assert-SafeRecoveryConfig',
    'Get-SafeRecoveryProfileOrder',
    'Test-SafeRecoveryAdmin',
    'Get-SafeRecoveryWatchdogStatus',
    'Invoke-SafeRecoveryReadOnlyNetsh',
    'ConvertFrom-SafeRecoveryProfileList',
    'Get-SafeRecoveryInstalledProfile',
    'Test-SafeRecoveryIsWirelessAdapter',
    'Select-SafeRecoveryWlanCandidate',
    'Resolve-SafeRecoveryWlanAdapter',
    'Test-SafeRecoveryIPv4Usable',
    'Format-SafeRecoveryProfileName',
    'Get-SafeRecoveryInterfaceState',
    'Test-SafeRecoveryConnectionHealthy',
    'New-SafeRecoveryLogSession',
    'Write-SafeRecoveryLog',
    'Write-SafeRecoveryStateSnapshot'
)

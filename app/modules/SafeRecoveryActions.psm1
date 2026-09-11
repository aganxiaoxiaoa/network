#Requires -Version 5.1
# ==============================================================================
# SafeRecoveryActions.psm1
# 独立安全恢复模块 - 受限写操作层 (Mutation Layer)
#
# 【本文件是整个工具箱内唯一被授权执行网络状态变更的文件】
# 经用户明确授权，且仅授权以下两项操作：
#   1) netsh wlan connect name=<白名单配置文件> interface=<已验证的物理无线网卡>
#   2) ipconfig /renew "<已验证的物理无线网卡名称>"
#
# 【永久禁止清单】以下操作在本文件中永久禁止，不得以任何理由新增：
#   - 禁止 ipconfig /release、/flushdns、/registerdns
#   - 禁止 netsh winsock reset、netsh int ip reset、netcfg -d
#   - 禁止 netsh wlan disconnect / delete profile / add profile / set profileparameter
#   - 禁止任何注册表写入、系统代理与 WinHTTP 代理修改
#   - 禁止 Disable-NetAdapter / Enable-NetAdapter / Restart-NetAdapter
#   - 禁止修改服务、计划任务、看门狗与路由器配置
#   - 禁止在失败后升级到上述任何其他修复手段 (失败必须停止并输出日志)
# ==============================================================================

Set-StrictMode -Version 2.0

# ------------------------------------------------------------------------------
# 受限写操作 1: 连接白名单内的 Wi-Fi 配置文件
# ------------------------------------------------------------------------------
function Invoke-SafeRecoveryWlanConnect {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$AllowedProfile,
        [Parameter(Mandatory = $true)][string]$InterfaceName
    )

    if ($AllowedProfile -notcontains $ProfileName) {
        throw "拒绝执行: 配置文件 '$ProfileName' 不在白名单 ($($AllowedProfile -join ', ')) 内。"
    }
    # 与代码级硬编码白名单再次交叉校验，配置文件被篡改也无法扩大授权范围
    $hardCoded = @(Get-SafeRecoveryHardCodedAllowedProfile)
    if ($hardCoded -notcontains $ProfileName) {
        throw "拒绝执行: 配置文件 '$ProfileName' 超出代码级硬编码授权白名单 ($($hardCoded -join ', '))。"
    }
    if ($ProfileName -notmatch '^[A-Za-z0-9_-]{1,32}$') {
        throw "拒绝执行: 配置文件名称 '$ProfileName' 含非受控字符。"
    }
    if ([string]::IsNullOrWhiteSpace($InterfaceName)) {
        throw '拒绝执行: 必须显式指定无线网卡名称，禁止让 netsh 自行选择接口。'
    }

    $target = "Wi-Fi 配置文件 '$ProfileName' (接口: $InterfaceName)"
    if (-not $PSCmdlet.ShouldProcess($target, 'netsh wlan connect')) {
        return [pscustomobject]@{
            Command  = "netsh wlan connect name=$ProfileName interface=$InterfaceName"
            ExitCode = $null
            Output   = ''
            Executed = $false
        }
    }

    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    if (-not (Test-Path -LiteralPath $netsh)) { $netsh = 'netsh.exe' }

    # 参数向量在此处硬编码构造，仅允许 connect 动词，不接受任何外部拼接
    $argumentList = @('wlan', 'connect', "name=$ProfileName", "interface=$InterfaceName")

    # 5.1 下 $ErrorActionPreference='Stop' + 2>&1 会把 stderr 变成终止性错误，
    # 导致读不到真实退出码，因此在原生调用处局部降级为 Continue。
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $output = & $netsh @argumentList 2>&1
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        Command  = "netsh $($argumentList -join ' ')"
        ExitCode = $exitCode
        Output   = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
        Executed = $true
    }
}

# ------------------------------------------------------------------------------
# 受限写操作 2: 仅对已验证的无线网卡续租 DHCP (绝不 release，绝不全局 renew)
# ------------------------------------------------------------------------------
function Invoke-SafeRecoveryDhcpRenew {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$InterfaceGuid,
        [Parameter(Mandatory = $true)][string]$ExpectedInterfaceName
    )

    # 续租前按 GUID 重新解析网卡，确认目标未发生漂移，且仍为无线网卡且启用 DHCP
    $state = Get-SafeRecoveryInterfaceState -InterfaceGuid $InterfaceGuid
    if ($state.AdapterName -ne $ExpectedInterfaceName) {
        throw "拒绝续租: 网卡名称已变化 (期望 '$ExpectedInterfaceName'，实际 '$($state.AdapterName)')。"
    }
    if ($null -eq $state.DhcpEnabled) {
        throw "拒绝续租: 无法确认接口 '$($state.AdapterName)' 的 DHCP 状态 (查询失败)，按安全边界不做任何修改。"
    }
    if ($state.DhcpEnabled -ne $true) {
        throw "拒绝续租: 接口 '$($state.AdapterName)' 未启用 DHCP (静态 IP 配置)，续租会破坏现有配置。"
    }

    $target = "无线网卡 '$($state.AdapterName)' (IfIndex: $($state.InterfaceIndex))"
    if (-not $PSCmdlet.ShouldProcess($target, 'ipconfig /renew')) {
        return [pscustomobject]@{
            Command  = "ipconfig /renew `"$($state.AdapterName)`""
            ExitCode = $null
            Output   = ''
            Executed = $false
        }
    }

    $ipconfig = Join-Path $env:SystemRoot 'System32\ipconfig.exe'
    if (-not (Test-Path -LiteralPath $ipconfig)) { $ipconfig = 'ipconfig.exe' }

    # 参数向量硬编码为 /renew + 单一接口名称；此处永久禁止出现 /release 与无接口名的全局续租
    $argumentList = @('/renew', $state.AdapterName)

    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $output = & $ipconfig @argumentList 2>&1
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        Command  = "ipconfig /renew `"$($state.AdapterName)`""
        ExitCode = $exitCode
        Output   = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
        Executed = $true
    }
}

# ------------------------------------------------------------------------------
# 状态轮询
# ------------------------------------------------------------------------------
function Test-SafeRecoveryWaitCondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][ValidateSet('Associated', 'UsableAddress')][string]$Condition,
        [Parameter(Mandatory = $false)][string]$ExpectedProfile
    )

    if ($Condition -eq 'Associated') {
        if ($State.MediaConnectionState -ne 'Connected') { return $false }
        return (Test-SafeRecoveryProfileMatch -State $State -ExpectedProfile $ExpectedProfile)
    }
    return ((Test-SafeRecoveryIPv4Usable -IPAddress $State.IPv4Address) -and $State.HasDefaultRoute -eq $true)
}

function Wait-SafeRecoveryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InterfaceGuid,
        [Parameter(Mandatory = $true)][ValidateSet('Associated', 'UsableAddress')][string]$Condition,
        [Parameter(Mandatory = $false)][string]$ExpectedProfile,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$PollIntervalMilliseconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        # 轮询期间不做网关 ICMP：它不参与判定，且会让轮询显著超出文档承诺的等待上限
        $state = Get-SafeRecoveryInterfaceState -InterfaceGuid $InterfaceGuid
        if (Test-SafeRecoveryWaitCondition -State $state -Condition $Condition -ExpectedProfile $ExpectedProfile) {
            return [pscustomobject]@{ Satisfied = $true; State = $state }
        }
        if ((Get-Date) -ge $deadline) {
            return [pscustomobject]@{ Satisfied = $false; State = $state }
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }
}

function New-SafeRecoveryAttemptResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][bool]$Succeeded,
        [Parameter(Mandatory = $false)]$ConnectExitCode = $null,
        [Parameter(Mandatory = $false)][bool]$MutationPerformed = $false,
        [Parameter(Mandatory = $false)][bool]$RenewPerformed = $false,
        [Parameter(Mandatory = $false)]$RenewExitCode = $null,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Reasons = @(),
        [Parameter(Mandatory = $false)]$FinalState = $null,
        [switch]$Cancelled
    )

    return [pscustomobject]@{
        Profile           = $ProfileName
        Succeeded         = $Succeeded
        ConnectExitCode   = $ConnectExitCode
        MutationPerformed = $MutationPerformed
        RenewPerformed    = $RenewPerformed
        RenewExitCode     = $RenewExitCode
        Reasons           = $Reasons
        FinalState        = $FinalState
        Cancelled         = [bool]$Cancelled
    }
}

# ------------------------------------------------------------------------------
# 单个配置文件的恢复尝试
# ------------------------------------------------------------------------------
function Invoke-SafeRecoveryProfileAttempt {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][int]$ConnectTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$DhcpWaitSeconds,
        [Parameter(Mandatory = $false)][string]$LogPath
    )

    $allowed = @($Config['AllowedProfiles'])
    $pollInterval = [int]$Config['PollIntervalMilliseconds']
    $pingCount = [int]$Config['GatewayPingCount']

    Write-SafeRecoveryLog -LogPath $LogPath -Message "--- 尝试恢复到配置文件 $ProfileName ---" -ForegroundColor Cyan

    $state = Get-SafeRecoveryInterfaceState -InterfaceGuid $Adapter.InterfaceGuid -GatewayPingCount $pingCount
    $health = Test-SafeRecoveryConnectionHealthy -State $state -ExpectedProfile $ProfileName
    if ($health.IsHealthy) {
        Write-SafeRecoveryLog -LogPath $LogPath -Message "已经连接在 $ProfileName 且网络可用，无需任何修改。" -ForegroundColor Green
        return New-SafeRecoveryAttemptResult -ProfileName $ProfileName -Succeeded $true -FinalState $state
    }

    # 步骤 1: 连接目标配置文件
    $connect = Invoke-SafeRecoveryWlanConnect -ProfileName $ProfileName -AllowedProfile $allowed -InterfaceName $Adapter.Name
    Write-SafeRecoveryLog -LogPath $LogPath -Message "执行: $($connect.Command) => ExitCode=$($connect.ExitCode)" -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace($connect.Output)) {
        Write-SafeRecoveryLog -LogPath $LogPath -Message "  输出: $($connect.Output -replace "`n", ' / ')" -ForegroundColor DarkGray
    }
    if (-not $connect.Executed) {
        # ShouldProcess 返回 false：本工具只在 -WhatIf 下出现该情况
        return New-SafeRecoveryAttemptResult -ProfileName $ProfileName -Succeeded $false -FinalState $state `
            -Reasons @('-WhatIf 预演: 未执行任何修改') -Cancelled
    }

    $connectExitCode = $connect.ExitCode
    if ($connectExitCode -ne 0) {
        return New-SafeRecoveryAttemptResult -ProfileName $ProfileName -Succeeded $false -ConnectExitCode $connectExitCode `
            -MutationPerformed $true -FinalState $state -Reasons @("netsh wlan connect 返回非零退出码 $connectExitCode")
    }

    # 步骤 2: 等待关联与安全握手真正完成 (退出码为 0 不代表已连接)
    $associated = Wait-SafeRecoveryState -InterfaceGuid $Adapter.InterfaceGuid -Condition 'Associated' `
        -ExpectedProfile $ProfileName -TimeoutSeconds $ConnectTimeoutSeconds -PollIntervalMilliseconds $pollInterval
    $state = $associated.State
    Write-SafeRecoveryStateSnapshot -LogPath $LogPath -Label "连接后 $ProfileName" -State $state -AllowedProfile $allowed
    if (-not $associated.Satisfied) {
        return New-SafeRecoveryAttemptResult -ProfileName $ProfileName -Succeeded $false -ConnectExitCode $connectExitCode `
            -MutationPerformed $true -FinalState $state `
            -Reasons @("在 $ConnectTimeoutSeconds 秒内未确认关联到 $ProfileName (WLAN 与 NLA 均未报告该配置文件)")
    }

    # 步骤 3: 先给 DHCP 自动完成的机会
    $autoWait = [int]$Config['DhcpAutoWaitSeconds']
    if ($autoWait -gt 0) {
        $auto = Wait-SafeRecoveryState -InterfaceGuid $Adapter.InterfaceGuid -Condition 'UsableAddress' `
            -TimeoutSeconds $autoWait -PollIntervalMilliseconds $pollInterval
        $state = $auto.State
    }

    # 步骤 4: 仍未取得可用地址时，只对该无线网卡续租一次 DHCP
    $renewPerformed = $false
    $renewExitCode = $null
    $extraReasons = New-Object System.Collections.Generic.List[string]
    if (-not (Test-SafeRecoveryIPv4Usable -IPAddress $state.IPv4Address)) {
        if ($null -eq $state.DhcpEnabled) {
            return New-SafeRecoveryAttemptResult -ProfileName $ProfileName -Succeeded $false -ConnectExitCode $connectExitCode `
                -MutationPerformed $true -FinalState $state `
                -Reasons @('无法确认该接口的 DHCP 状态 (查询失败)，按安全边界拒绝续租')
        }
        if ($state.DhcpEnabled -ne $true) {
            return New-SafeRecoveryAttemptResult -ProfileName $ProfileName -Succeeded $false -ConnectExitCode $connectExitCode `
                -MutationPerformed $true -FinalState $state `
                -Reasons @('该接口未启用 DHCP (静态 IP 配置)，按安全边界拒绝续租')
        }

        $renew = Invoke-SafeRecoveryDhcpRenew -InterfaceGuid $Adapter.InterfaceGuid -ExpectedInterfaceName $Adapter.Name
        $renewPerformed = $renew.Executed
        $renewExitCode = $renew.ExitCode
        Write-SafeRecoveryLog -LogPath $LogPath -Message "执行: $($renew.Command) => ExitCode=$renewExitCode" -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace($renew.Output)) {
            Write-SafeRecoveryLog -LogPath $LogPath -Message "  输出: $($renew.Output -replace "`n", ' / ')" -ForegroundColor DarkGray
        }
        # 原生命令退出码必须检查：非零时记录为失败原因 (最终仍以后置条件为准)
        if ($renewPerformed -and $renewExitCode -ne 0) {
            $extraReasons.Add("ipconfig /renew 返回非零退出码 $renewExitCode")
            Write-SafeRecoveryLog -LogPath $LogPath -Message "[警告] ipconfig /renew 退出码为 $renewExitCode" -ForegroundColor Yellow
        }

        $leased = Wait-SafeRecoveryState -InterfaceGuid $Adapter.InterfaceGuid -Condition 'UsableAddress' `
            -TimeoutSeconds $DhcpWaitSeconds -PollIntervalMilliseconds $pollInterval
        $state = $leased.State
    }

    # 步骤 5: 最终后置条件校验 (网关 Ping 仅记录，不参与判定)
    $state = Get-SafeRecoveryInterfaceState -InterfaceGuid $Adapter.InterfaceGuid -GatewayPingCount $pingCount
    $health = Test-SafeRecoveryConnectionHealthy -State $state -ExpectedProfile $ProfileName
    Write-SafeRecoveryStateSnapshot -LogPath $LogPath -Label "最终 $ProfileName" -State $state -AllowedProfile $allowed

    $reasons = @($health.Reasons) + @($extraReasons.ToArray())
    return New-SafeRecoveryAttemptResult -ProfileName $ProfileName -Succeeded $health.IsHealthy -ConnectExitCode $connectExitCode `
        -MutationPerformed $true -RenewPerformed $renewPerformed -RenewExitCode $renewExitCode `
        -Reasons $reasons -FinalState $state
}

# ------------------------------------------------------------------------------
# 全部尝试失败后的尽力回退：只连接恢复前那个白名单配置文件，不做任何其他动作
# ------------------------------------------------------------------------------
function Restore-SafeRecoveryOriginalProfile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [Parameter(Mandatory = $true)][string]$OriginalProfile,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $false)][string]$LogPath
    )

    $allowed = @($Config['AllowedProfiles'])
    Write-SafeRecoveryLog -LogPath $LogPath -Message "[回退] 正在尝试恢复到操作前的配置文件 $OriginalProfile ..." -ForegroundColor Yellow
    try {
        $connect = Invoke-SafeRecoveryWlanConnect -ProfileName $OriginalProfile -AllowedProfile $allowed -InterfaceName $Adapter.Name
        Write-SafeRecoveryLog -LogPath $LogPath -Message "执行: $($connect.Command) => ExitCode=$($connect.ExitCode)" -ForegroundColor Yellow
        if (-not $connect.Executed) { return $false }

        $associated = Wait-SafeRecoveryState -InterfaceGuid $Adapter.InterfaceGuid -Condition 'Associated' `
            -ExpectedProfile $OriginalProfile -TimeoutSeconds ([int]$Config['ConnectTimeoutSeconds']) `
            -PollIntervalMilliseconds ([int]$Config['PollIntervalMilliseconds'])
        Write-SafeRecoveryStateSnapshot -LogPath $LogPath -Label "回退后 $OriginalProfile" -State $associated.State -AllowedProfile $allowed
        return [bool]$associated.Satisfied
    } catch {
        Write-SafeRecoveryLog -LogPath $LogPath -Message "[回退失败] $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ------------------------------------------------------------------------------
# 恢复编排 (唯一对外入口)
# 退出码: 0 成功 / 1 未做任何修改的环境或配置错误 / 2 已尝试但网络仍不可用 / 3 用户取消
# ------------------------------------------------------------------------------
function Invoke-SafeNetworkRecovery {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string[]]$ProfileOrder,
        [Parameter(Mandatory = $false)][string]$InterfaceGuid,
        [Parameter(Mandatory = $false)][int]$ConnectTimeoutSeconds = 0,
        [Parameter(Mandatory = $false)][int]$DhcpWaitSeconds = 0,
        [switch]$ProfileExplicitlyRequested
    )

    $allowed = @($Config['AllowedProfiles'])
    if ($ConnectTimeoutSeconds -le 0) { $ConnectTimeoutSeconds = [int]$Config['ConnectTimeoutSeconds'] }
    if ($DhcpWaitSeconds -le 0) { $DhcpWaitSeconds = [int]$Config['DhcpWaitSeconds'] }

    $logPath = New-SafeRecoveryLogSession -ToolRoot $ToolRoot -LogSubDirectory ([string]$Config['LogSubDirectory'])
    Write-SafeRecoveryLog -LogPath $logPath -Message '=======================================================================' -ForegroundColor Cyan
    Write-SafeRecoveryLog -LogPath $logPath -Message '独立安全网络恢复 (仅允许切换 701/702 与无线 DHCP 续租)' -ForegroundColor Cyan
    Write-SafeRecoveryLog -LogPath $logPath -Message '禁止修改代理 / Winsock / 注册表 / Wi-Fi 配置文件 / 网卡启停 / 服务' -ForegroundColor Cyan
    Write-SafeRecoveryLog -LogPath $logPath -Message '=======================================================================' -ForegroundColor Cyan
    Write-SafeRecoveryLog -LogPath $logPath -Message "日志文件: $logPath" -ForegroundColor Gray

    $noChange = [pscustomobject]@{ ExitCode = 1; Succeeded = $false; ProfileUsed = $null; LogPath = $logPath; Attempts = @(); MutationPerformed = $false }

    if (-not (Test-SafeRecoveryAdmin)) {
        Write-SafeRecoveryLog -LogPath $logPath -Message '[中止] DHCP 续租需要管理员权限，当前不是管理员。未做任何修改。' -ForegroundColor Red
        return $noChange
    }

    # 看门狗只读检测: 只提示，绝不停止或修改
    $watchdog = Get-SafeRecoveryWatchdogStatus
    if ($watchdog.IsActive) {
        Write-SafeRecoveryLog -LogPath $logPath -Message "[警告] 检测到本地看门狗处于活动状态 (任务: $($watchdog.TaskState), PID: $($watchdog.ProcessId))。" -ForegroundColor Yellow
        Write-SafeRecoveryLog -LogPath $logPath -Message '        本工具不会停止或修改看门狗；但恢复过程中的瞬时切换可能与它的判定重叠。' -ForegroundColor Yellow
    } else {
        Write-SafeRecoveryLog -LogPath $logPath -Message '本地看门狗未处于活动状态。' -ForegroundColor Gray
    }

    try {
        $adapter = Resolve-SafeRecoveryWlanAdapter -ExpectedInterfaceGuid $InterfaceGuid
    } catch {
        Write-SafeRecoveryLog -LogPath $logPath -Message "[中止] $($_.Exception.Message) 未做任何修改。" -ForegroundColor Red
        return $noChange
    }
    Write-SafeRecoveryLog -LogPath $logPath -Message "目标无线网卡: $($adapter.Name) | $($adapter.InterfaceDescription) | IfIndex=$($adapter.InterfaceIndex) | GUID=$($adapter.InterfaceGuid)" -ForegroundColor Gray

    try {
        $beforeState = Get-SafeRecoveryInterfaceState -InterfaceGuid $adapter.InterfaceGuid -GatewayPingCount ([int]$Config['GatewayPingCount'])
    } catch {
        Write-SafeRecoveryLog -LogPath $logPath -Message "[中止] 读取恢复前状态失败: $($_.Exception.Message) 未做任何修改。" -ForegroundColor Red
        return $noChange
    }
    Write-SafeRecoveryStateSnapshot -LogPath $logPath -Label '恢复前' -State $beforeState -AllowedProfile $allowed

    # 恢复前若已在某个白名单配置文件上，记录下来用于失败回退
    $originalProfile = Get-SafeRecoveryActiveAllowedProfile -State $beforeState -AllowedProfile $allowed
    $originalHealthy = $false
    if ($null -ne $originalProfile) {
        $originalHealthy = (Test-SafeRecoveryConnectionHealthy -State $beforeState -ExpectedProfile $originalProfile).IsHealthy
    }

    # 关键安全行为: 当前网络已经可用时，默认绝不去动它 (避免把在线用户切下线)
    if ($originalHealthy -and -not $ProfileExplicitlyRequested) {
        Write-SafeRecoveryLog -LogPath $logPath -Message "[无需恢复] 当前已连接 $originalProfile 且网络可用 (IPv4=$($beforeState.IPv4Address))，未做任何修改。" -ForegroundColor Green
        Write-SafeRecoveryLog -LogPath $logPath -Message '        如确实要切换到另一个配置文件，请显式使用 -TargetProfile。' -ForegroundColor Gray
        return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; ProfileUsed = $originalProfile; LogPath = $logPath; Attempts = @(); MutationPerformed = $false }
    }

    # 只使用本机已保存的配置文件，绝不创建、修改或删除任何 Wi-Fi 配置文件
    try {
        $installed = @(Get-SafeRecoveryInstalledProfile -InterfaceName $adapter.Name)
    } catch {
        Write-SafeRecoveryLog -LogPath $logPath -Message "[中止] $($_.Exception.Message) 未做任何修改。" -ForegroundColor Red
        return $noChange
    }
    $plan = @($ProfileOrder | Where-Object { $installed -contains $_ })
    $missing = @($ProfileOrder | Where-Object { $installed -notcontains $_ })
    foreach ($name in $missing) {
        Write-SafeRecoveryLog -LogPath $logPath -Message "[跳过] 本机未保存 Wi-Fi 配置文件 '$name' (本工具绝不创建配置文件)。" -ForegroundColor Yellow
    }
    if ($plan.Count -eq 0) {
        Write-SafeRecoveryLog -LogPath $logPath -Message '[中止] 白名单内没有任何已保存的 Wi-Fi 配置文件可用。未做任何修改。' -ForegroundColor Red
        return $noChange
    }

    Write-SafeRecoveryLog -LogPath $logPath -Message "恢复顺序: $($plan -join ' -> ')" -ForegroundColor Cyan
    Write-SafeRecoveryLog -LogPath $logPath -Message "将要执行的操作: netsh wlan connect (仅白名单配置文件) + 必要时 ipconfig /renew `"$($adapter.Name)`"" -ForegroundColor Cyan
    if ($originalHealthy) {
        Write-SafeRecoveryLog -LogPath $logPath -Message "[重要警告] 当前 $originalProfile 网络本来是可用的，继续操作会主动断开它！" -ForegroundColor Red
    }

    if ($WhatIfPreference) {
        Write-SafeRecoveryLog -LogPath $logPath -Message '[WhatIf] 仅展示计划，未执行任何网络修改。' -ForegroundColor Green
        return [pscustomobject]@{ ExitCode = 0; Succeeded = $false; ProfileUsed = $null; LogPath = $logPath; Attempts = @(); MutationPerformed = $false; WhatIf = $true }
    }

    # 唯一人工确认环节 (不受 -Confirm:$false 影响，无任何跳过参数)
    $token = [string]$Config['ConfirmationToken']
    Write-Host ''
    if ($originalHealthy) {
        Write-Host "警告: 你当前在 $originalProfile 上网络是正常的，继续会主动断开它。" -ForegroundColor Red
    }
    Write-Host "即将尝试 $($plan -join ' -> ')，失败会自动回退，网络会短暂中断。" -ForegroundColor Yellow
    Write-Host "请逐字输入 $token 继续 (直接回车即取消): " -ForegroundColor Yellow -NoNewline
    $answer = Read-Host
    if ($answer.Trim() -cne $token) {
        Write-SafeRecoveryLog -LogPath $logPath -Message '[取消] 用户未确认，未执行任何网络修改。' -ForegroundColor Yellow
        return [pscustomobject]@{ ExitCode = 3; Succeeded = $false; ProfileUsed = $null; LogPath = $logPath; Attempts = @(); MutationPerformed = $false }
    }
    Write-SafeRecoveryLog -LogPath $logPath -Message '用户已确认，开始执行受限恢复操作。' -ForegroundColor Green -NoConsole

    $attempts = New-Object System.Collections.Generic.List[object]
    $succeededProfile = $null
    $mutationPerformed = $false
    $cancelled = $false

    foreach ($profileName in $plan) {
        # 每个尝试独立容错：轮询期间网卡瞬时消失等异常不得终止整个流程，
        # 也不得被误报成「未做任何修改的环境错误」
        try {
            $attempt = Invoke-SafeRecoveryProfileAttempt -Adapter $adapter -ProfileName $profileName -Config $Config `
                -ConnectTimeoutSeconds $ConnectTimeoutSeconds -DhcpWaitSeconds $DhcpWaitSeconds -LogPath $logPath
        } catch {
            $mutationPerformed = $true
            $attempt = New-SafeRecoveryAttemptResult -ProfileName $profileName -Succeeded $false -MutationPerformed $true `
                -Reasons @("尝试过程中出现异常: $($_.Exception.Message)")
            Write-SafeRecoveryLog -LogPath $logPath -Message "[异常] $profileName 尝试中断: $($_.Exception.Message)" -ForegroundColor Red
        }
        $attempts.Add($attempt)
        if ($attempt.MutationPerformed) { $mutationPerformed = $true }
        if ($attempt.Cancelled) { $cancelled = $true; break }

        if ($attempt.Succeeded) {
            $succeededProfile = $profileName
            Write-SafeRecoveryLog -LogPath $logPath -Message "[成功] 已在 $profileName 上取得可用 IPv4 与默认路由。" -ForegroundColor Green
            break
        }

        foreach ($reason in @($attempt.Reasons)) {
            Write-SafeRecoveryLog -LogPath $logPath -Message "[失败原因] $profileName : $reason" -ForegroundColor Red
        }
    }

    if ($cancelled) {
        return [pscustomobject]@{ ExitCode = 3; Succeeded = $false; ProfileUsed = $null; LogPath = $logPath; Attempts = $attempts.ToArray(); MutationPerformed = $mutationPerformed }
    }

    if ($null -eq $succeededProfile) {
        Write-SafeRecoveryLog -LogPath $logPath -Message '[停止] 白名单内所有配置文件均未恢复成功。按安全边界，本工具不会再执行任何其他修复手段。' -ForegroundColor Red

        # 尽力回退到操作前的配置文件，避免让用户比操作前更差
        if ($mutationPerformed -and $null -ne $originalProfile) {
            $lastState = $null
            if ($attempts.Count -gt 0) { $lastState = $attempts[$attempts.Count - 1].FinalState }
            $stillOnOriginal = $false
            if ($null -ne $lastState) {
                $stillOnOriginal = Test-SafeRecoveryProfileMatch -State $lastState -ExpectedProfile $originalProfile
            }
            if (-not $stillOnOriginal) {
                $restored = Restore-SafeRecoveryOriginalProfile -Adapter $adapter -OriginalProfile $originalProfile -Config $Config -LogPath $logPath
                if ($restored) {
                    Write-SafeRecoveryLog -LogPath $logPath -Message "[回退成功] 已重新关联到操作前的配置文件 $originalProfile。" -ForegroundColor Yellow
                } else {
                    Write-SafeRecoveryLog -LogPath $logPath -Message "[回退未成功] 未能重新关联到 $originalProfile，请手动在任务栏 Wi-Fi 中连接。" -ForegroundColor Red
                }
            }
        }

        Write-SafeRecoveryLog -LogPath $logPath -Message '        可使用 START-DIAGNOSIS.cmd 采集证据后进一步排查路由器侧 DHCP。' -ForegroundColor Yellow
        return [pscustomobject]@{ ExitCode = 2; Succeeded = $false; ProfileUsed = $null; LogPath = $logPath; Attempts = $attempts.ToArray(); MutationPerformed = $mutationPerformed }
    }

    return [pscustomobject]@{
        ExitCode          = 0
        Succeeded         = $true
        ProfileUsed       = $succeededProfile
        LogPath           = $logPath
        Attempts          = $attempts.ToArray()
        MutationPerformed = $mutationPerformed
    }
}

# ------------------------------------------------------------------------------
# 只读预检 (Status): 不执行任何修改
# ------------------------------------------------------------------------------
function Get-SafeRecoveryPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string[]]$ProfileOrder,
        [Parameter(Mandatory = $false)][string]$InterfaceGuid
    )

    $allowed = @($Config['AllowedProfiles'])
    Write-Host '=======================================================================' -ForegroundColor Cyan
    Write-Host '安全恢复预检 (纯只读，不会修改任何网络设置)' -ForegroundColor Cyan
    Write-Host '=======================================================================' -ForegroundColor Cyan

    $isAdmin = Test-SafeRecoveryAdmin
    Write-Host " 管理员权限: $(if ($isAdmin) { '是' } else { '否 (执行恢复时会请求 UAC)' })" -ForegroundColor Gray

    $watchdog = Get-SafeRecoveryWatchdogStatus
    Write-Host " 本地看门狗: 任务状态=$($watchdog.TaskState), PID=$($watchdog.ProcessId), 活动=$($watchdog.IsActive)" -ForegroundColor Gray

    $adapter = Resolve-SafeRecoveryWlanAdapter -ExpectedInterfaceGuid $InterfaceGuid
    Write-Host " 无线网卡: $($adapter.Name) | $($adapter.InterfaceDescription) | IfIndex=$($adapter.InterfaceIndex)" -ForegroundColor Gray

    $state = Get-SafeRecoveryInterfaceState -InterfaceGuid $adapter.InterfaceGuid -GatewayPingCount ([int]$Config['GatewayPingCount'])
    $wlanText = Format-SafeRecoveryProfileName -Name $state.WlanProfile -AllowedProfile $allowed
    $nlaText = Format-SafeRecoveryProfileName -Name $state.ConnectedProfile -AllowedProfile $allowed
    Write-Host " 当前网络: WLAN=$wlanText / NLA=$nlaText | Media=$($state.MediaConnectionState) | IPv4=$($state.IPv4Address) | Dhcp=$($state.DhcpEnabled) | Gateway=$($state.DefaultGateway)" -ForegroundColor Gray

    $activeProfile = Get-SafeRecoveryActiveAllowedProfile -State $state -AllowedProfile $allowed
    $activeHealthy = $false
    if ($null -ne $activeProfile) {
        $activeHealthy = (Test-SafeRecoveryConnectionHealthy -State $state -ExpectedProfile $activeProfile).IsHealthy
    }
    if ($activeHealthy) {
        Write-Host " 结论: 当前 $activeProfile 网络已可用；直接执行恢复将不做任何修改 (除非显式 -TargetProfile)" -ForegroundColor Green
    } else {
        Write-Host ' 结论: 当前网络不可用，执行恢复会尝试连接白名单配置文件' -ForegroundColor Yellow
    }

    $installed = @(Get-SafeRecoveryInstalledProfile -InterfaceName $adapter.Name)
    foreach ($name in $allowed) {
        $exists = $installed -contains $name
        $color = if ($exists) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-Host " 白名单配置文件 $name : $(if ($exists) { '已保存' } else { '本机未保存 (会被跳过)' })" -ForegroundColor $color
    }

    $plan = @($ProfileOrder | Where-Object { $installed -contains $_ })
    Write-Host " 若执行恢复，尝试顺序: $($plan -join ' -> ')" -ForegroundColor Cyan
    Write-Host ' 允许的写操作仅两项: netsh wlan connect (白名单) 与 ipconfig /renew (仅该无线网卡)' -ForegroundColor Cyan

    return [pscustomobject]@{
        ExitCode      = 0
        Adapter       = $adapter
        State         = $state
        Installed     = $installed
        Plan          = $plan
        ActiveProfile = $activeProfile
        ActiveHealthy = $activeHealthy
    }
}

Export-ModuleMember -Function @(
    'Invoke-SafeRecoveryWlanConnect',
    'Invoke-SafeRecoveryDhcpRenew',
    'Test-SafeRecoveryWaitCondition',
    'Wait-SafeRecoveryState',
    'New-SafeRecoveryAttemptResult',
    'Invoke-SafeRecoveryProfileAttempt',
    'Restore-SafeRecoveryOriginalProfile',
    'Invoke-SafeNetworkRecovery',
    'Get-SafeRecoveryPreflight'
)

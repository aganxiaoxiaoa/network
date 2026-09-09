# ==============================================================================
# RecoveryActions.psm1
# 便携网络恢复与诊断工具箱 - 安全恢复与状态变更模块
# 严格遵循：
#  1. CmdletBinding(SupportsShouldProcess = $true)
#  2. 严禁使用不存在的参数 (如 Disable-NetAdapter -InterfaceIndex)
#  3. 严禁执行 netcfg -d
#  4. 严禁修改 WinHTTP 代理
#  5. 深度重置前全面检测非 Loopback 静态 IP (包括 Disconnected 状态)
#  6. 代理快照基于相对路径，支持精确恢复与指针自动搜寻
# ==============================================================================

Set-StrictMode -Version 2.0

function Save-NetworkSnapshot {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Reason = "Generic",
        [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot)
    )

    $snapshotDir = Join-Path $ToolRoot "output\snapshots"
    $ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $fileName = "Snapshot-$ts-$Reason.json"
    $targetPath = Join-Path $snapshotDir $fileName
    $relativePath = "snapshots\$fileName"

    if (-not $PSCmdlet.ShouldProcess($targetPath, "保存网络状态快照")) {
        return $null
    }

    if (-not (Test-Path $snapshotDir)) {
        New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    }

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $props = if (Test-Path $regPath) { Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue } else { $null }

    $snapshotData = [PSCustomObject]@{
        Timestamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Reason      = $Reason
        Adapters    = @(Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name, InterfaceAlias, InterfaceIndex, InterfaceGuid, InterfaceDescription, Status, HardwareInterface, MacAddress)
        IPInterfaces = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object InterfaceAlias, InterfaceIndex, Dhcp, ConnectionState)
        IPAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength)
        Routes      = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object DestinationPrefix, NextHop, RouteMetric, InterfaceMetric, InterfaceIndex, InterfaceAlias)
        DnsServers  = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object InterfaceAlias, InterfaceIndex, ServerAddresses)
        WinInetProxy = [PSCustomObject]@{
            ProxyEnable   = if ($props -and ($null -ne $props.ProxyEnable)) { [int]$props.ProxyEnable } else { $null }
            ProxyServer   = if ($props -and ($null -ne $props.ProxyServer)) { [string]$props.ProxyServer } else { $null }
            ProxyOverride = if ($props -and ($null -ne $props.ProxyOverride)) { [string]$props.ProxyOverride } else { $null }
            AutoConfigURL = if ($props -and ($null -ne $props.AutoConfigURL)) { [string]$props.AutoConfigURL } else { $null }
            AutoDetect    = if ($props -and ($null -ne $props.AutoDetect)) { [int]$props.AutoDetect } else { $null }
        }
    }

    $json = $snapshotData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($targetPath, $json, [System.Text.Encoding]::UTF8)
    Write-Host "   [快照] 已保存网络状态快照: $fileName" -ForegroundColor Cyan
    return $relativePath
}

function Invoke-SafeRepair {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot)
    )

    if (-not $PSCmdlet.ShouldProcess("本机网络环境", "执行安全修复 (刷新 DNS 与 DHCP 续租)")) {
        return
    }

    Write-Host "=======================================================================" -ForegroundColor Cyan
    Write-Host "              执行安全修复：刷新 DNS 缓存，按条件续租 DHCP              " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan

    # 1. 保存前置快照
    Save-NetworkSnapshot -Reason "BeforeSafeRepair" -ToolRoot $ToolRoot

    # 2. 刷新 DNS
    Write-Host "`n[步骤 1/2] 正在刷新 DNS 客户端解析缓存..." -ForegroundColor Yellow
    try {
        $flushRes = (ipconfig /flushdns 2>&1) -join "`n"
        Write-Host "   - $flushRes" -ForegroundColor Green
    } catch {
        Write-Host "   - [错误] 刷新 DNS 异常: $($_.Exception.Message)" -ForegroundColor Red
    }

    # 3. 按条件续租 DHCP
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric } | Select-Object -First 1

    $prefIndex = if ($route) { [int]$route.InterfaceIndex } else { 0 }
    $nic = Get-ActivePhysicalAdapter -PreferredInterfaceIndex $prefIndex

    Write-Host "`n[步骤 2/2] 正在核验活动物理网卡的 DHCP 模式..." -ForegroundColor Yellow
    if ($nic.Found) {
        $ipIntf = Get-NetIPInterface -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ipIntf -and $ipIntf.Dhcp -eq 'Enabled') {
            Write-Host "   - 网卡 $($nic.Name) 为 DHCP 动态获取模式，正在安全续租 IP 租约..." -ForegroundColor Yellow
            Write-Host "   - [注意] 绝不执行 /release，避免在路由器异常时主动丢弃可用地址。" -ForegroundColor Gray
            try {
                $renewRes = (ipconfig /renew $nic.Name 2>&1) -join "`n"
                Write-Host "   - 续租执行完成。" -ForegroundColor Green
            } catch {
                Write-Host "   - [错误] DHCP 续租异常: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host "   - 活动物理网卡 '$($nic.Name)' 为静态 IP 配置 (Dhcp=Disabled)。" -ForegroundColor Yellow
            Write-Host "   - [安全跳过] 静态 IP 接口自动跳过 DHCP 续租操作，防止网络中断或配置冲突。" -ForegroundColor Green
        }
    } else {
        Write-Host "   - 未找到活动物理网卡，安全跳过 DHCP 续租。" -ForegroundColor Yellow
    }

    Write-Host "`n正在重新运行网络健康诊断以比对修复效果..." -ForegroundColor Cyan
    Invoke-FullDiagnostic
}

function Invoke-ReconnectAdapter {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [int]$InterfaceIndex,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedGuid,
        [string]$ConfirmationToken = "",
        [switch]$Force
    )

    # 1. 严格核验
    $nic = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $nic) {
        Write-Host "[错误] 无法找到索引为 $InterfaceIndex 的网络适配器！" -ForegroundColor Red
        return $false
    }

    if ($nic.InterfaceGuid -ne $ExpectedGuid) {
        Write-Host "[拒绝] 适配器 GUID 不匹配！当前 GUID: $($nic.InterfaceGuid)，预期: $ExpectedGuid" -ForegroundColor Red
        return $false
    }

    if (-not $nic.HardwareInterface) {
        Write-Host "[拒绝] 目标适配器 HardwareInterface 为 False，非真实物理网卡，禁止执行重连！" -ForegroundColor Red
        return $false
    }

    # 2. 风险警告与确认
    Write-Host "=======================================================================" -ForegroundColor Red
    Write-Host "                        高风险操作警告：物理网卡重连                   " -ForegroundColor Red
    Write-Host "=======================================================================" -ForegroundColor Red
    Write-Host " 目标网卡: $($nic.Name)" -ForegroundColor Yellow
    Write-Host " 硬件型号: $($nic.InterfaceDescription)" -ForegroundColor Yellow
    Write-Host " 接口索引: $($nic.InterfaceIndex) (GUID: $($nic.InterfaceGuid))" -ForegroundColor Yellow
    Write-Host "`n 警告：此操作将禁用并重新启用该物理网卡，将导致：" -ForegroundColor Red
    Write-Host "   1. 正在进行的 VPN / 代理连接断开" -ForegroundColor Red
    Write-Host "   2. 正在进行的网络下载 / 远程桌面 / SSH 会话瞬间中断" -ForegroundColor Red
    Write-Host "   3. 任何依赖当前网卡的 Agent 会话连接中断" -ForegroundColor Red
    Write-Host "=======================================================================" -ForegroundColor Red

    if (-not $Force) {
        if ($ConfirmationToken -ne "RESTART") {
            Write-Host "请输入精确确认指令 [RESTART] 以继续，或按回车取消:" -ForegroundColor Yellow -NoNewline
            $inputVal = Read-Host
            if ($inputVal -ne "RESTART") {
                Write-Host "操作已取消。" -ForegroundColor Green
                return $false
            }
        }
    }

    # 3. 严格使用管道执行，并在 finally 中尽最大努力确保网卡重新启用
    if (-not $PSCmdlet.ShouldProcess("$($nic.Name)", "禁用并重新启用物理网络适配器")) {
        return $false
    }

    Write-Host "正在重连物理网卡 '$($nic.Name)'..." -ForegroundColor Yellow
    try {
        $nic | Disable-NetAdapter -Confirm:$false -ErrorAction Stop
        Write-Host "   - 网卡已禁用，等待 3 秒以彻底重置硬件总线链路..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
    } finally {
        $currentNic = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue
        if ($currentNic) {
            $currentNic | Enable-NetAdapter -Confirm:$false -ErrorAction Stop
            Write-Host "   - 网卡已重新启用。" -ForegroundColor Green
        } else {
            Write-Host "   - [严重警告] 无法重新定位目标网卡进行启用！" -ForegroundColor Red
        }
    }
    return $true
}

function Invoke-DeepReset {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot),
        [string]$ConfirmationToken = "",
        [switch]$Force
    )

    Write-Host "=======================================================================" -ForegroundColor Magenta
    Write-Host "              深度重置 Winsock / TCP-IP 基础协议栈 (最终手段)           " -ForegroundColor Magenta
    Write-Host "=======================================================================" -ForegroundColor Magenta

    # 1. 检查所有非 Loopback 静态 IPv4 接口 (包含 Disconnected 状态)
    $staticInterfaces = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.Dhcp -eq 'Disabled' }

    if ($staticInterfaces -and $staticInterfaces.Count -gt 0) {
        Write-Host "[拒绝执行] 系统中检测到以下已配置静态 IP 的网络接口 (Dhcp=Disabled):" -ForegroundColor Red
        foreach ($s in $staticInterfaces) {
            Write-Host "   - 接口索引: $($s.InterfaceIndex), 别名: $($s.InterfaceAlias), 连接状态: $($s.ConnectionState)" -ForegroundColor Yellow
        }
        Write-Host "`n深度重置 (netsh int ip reset) 会彻底抹除静态 IP 与网关配置，可能导致机器离线。" -ForegroundColor Red
        Write-Host "默认保护策略已拦截此操作。如确需重置，请先备份静态 IP 信息。" -ForegroundColor Red
        return $false
    }

    # 2. 警告并确认
    Write-Host "警告：深度重置将初始化 Winsock 目录与 TCP/IP 协议栈至出厂状态。" -ForegroundColor Yellow
    Write-Host "本工具绝不执行破坏性的 netcfg -d (netcfg -d 会破坏 VPN/虚拟交换机组件)。" -ForegroundColor Gray
    Write-Host "执行完成后需要手动重启计算机方可彻底生效。`n" -ForegroundColor Yellow

    if (-not $Force) {
        if ($ConfirmationToken -ne "DEEP-RESET") {
            Write-Host "请输入精确确认指令 [DEEP-RESET] 以继续，或按回车取消:" -ForegroundColor Yellow -NoNewline
            $inputVal = Read-Host
            if ($inputVal -ne "DEEP-RESET") {
                Write-Host "操作已取消。" -ForegroundColor Green
                return $false
            }
        }
    }

    # 3. 检查 ShouldProcess
    if (-not $PSCmdlet.ShouldProcess("系统 TCP/IP 与 Winsock 协议栈", "执行 netsh winsock reset, netsh int ip reset, ipconfig /flushdns")) {
        return $false
    }

    # 4. 前置快照
    Save-NetworkSnapshot -Reason "BeforeDeepReset" -ToolRoot $ToolRoot

    Write-Host "正在重置 Winsock 目录..." -ForegroundColor Yellow
    netsh winsock reset | Out-Null
    Write-Host "   - Winsock 重置完成。" -ForegroundColor Green

    Write-Host "正在重置 TCP/IP 协议栈..." -ForegroundColor Yellow
    netsh int ip reset | Out-Null
    Write-Host "   - TCP/IP 协议栈重置完成。" -ForegroundColor Green

    Write-Host "正在清空 DNS 缓存..." -ForegroundColor Yellow
    ipconfig /flushdns | Out-Null
    Write-Host "   - DNS 缓存已清空。" -ForegroundColor Green

    Write-Host "`n=======================================================================" -ForegroundColor Green
    Write-Host " 深度重置已执行完毕！" -ForegroundColor Green
    Write-Host " [提示] 本工具遵循安全规范，不会自动重启电脑。" -ForegroundColor Yellow
    Write-Host " 请您在合适时机【手动重启计算机】，以便 Windows 核心驱动完全重新加载！" -ForegroundColor Yellow
    Write-Host "=======================================================================" -ForegroundColor Green
    return $true
}

function Invoke-ResetProxyToDirect {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot),
        [string]$ConfirmationToken = "",
        [switch]$Force
    )

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    if (-not (Test-Path $regPath)) {
        Write-Host "[错误] 未找到当前用户的 WinINET 注册表路径！" -ForegroundColor Red
        return $false
    }

    $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue

    # 1. 采集当前精确状态
    $keys = @("ProxyEnable", "ProxyServer", "ProxyOverride", "AutoConfigURL", "AutoDetect")
    $snapshotValues = @{}

    foreach ($k in $keys) {
        $p = $props.PSObject.Properties[$k]
        if ($p -and $null -ne $p.Value) {
            $snapshotValues[$k] = [PSCustomObject]@{
                Present = $true
                Value   = $p.Value
            }
        } else {
            $snapshotValues[$k] = [PSCustomObject]@{
                Present = $false
                Value   = $null
            }
        }
    }

    Write-Host "=======================================================================" -ForegroundColor Cyan
    Write-Host "        清除当前用户 WinINET 手动代理/PAC 脚本，恢复系统直连           " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan
    $curPEnable = if ($props.PSObject.Properties['ProxyEnable']) { $props.ProxyEnable } else { 0 }
    $curPServer = if ($props.PSObject.Properties['ProxyServer']) { $props.ProxyServer } else { "[未配置]" }
    $curPAuto   = if ($props.PSObject.Properties['AutoConfigURL']) { $props.AutoConfigURL } else { "[未配置]" }
    $curPOver   = if ($props.PSObject.Properties['ProxyOverride']) { $props.ProxyOverride } else { "[未配置]" }

    Write-Host " 当前代理状态:" -ForegroundColor Yellow
    Write-Host "   - ProxyEnable: $curPEnable"
    Write-Host "   - ProxyServer: $curPServer"
    Write-Host "   - AutoConfigURL: $curPAuto"
    Write-Host "   - ProxyOverride: $curPOver"
    Write-Host "`n [安全承诺] 仅修改当前用户 WinINET 注册表，绝对不执行 netsh winhttp reset proxy。" -ForegroundColor Gray

    if (-not $Force) {
        if ($ConfirmationToken -ne "DIRECT") {
            Write-Host "`n请输入精确确认指令 [DIRECT] 以继续，或按回车取消:" -ForegroundColor Yellow -NoNewline
            $inputVal = Read-Host
            if ($inputVal -ne "DIRECT") {
                Write-Host "操作已取消。" -ForegroundColor Green
                return $false
            }
        }
    }

    if (-not $PSCmdlet.ShouldProcess($regPath, "备份并清除 WinINET 代理设置")) {
        return $false
    }

    # 2. 保存代理快照
    $snapshotDir = Join-Path $ToolRoot "output\snapshots"
    $ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $snapFile = "ProxySnapshot-$ts-ResetProxy.json"
    $snapFullPath = Join-Path $snapshotDir $snapFile
    $relativeSnapPath = "snapshots\$snapFile"

    if (-not (Test-Path $snapshotDir)) {
        New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    }

    $snapObj = [PSCustomObject]@{
        Timestamp        = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Reason           = "ResetProxy"
        RelativeSnapshot = $relativeSnapPath
        Settings         = $snapshotValues
    }
    $json = $snapObj | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($snapFullPath, $json, [System.Text.Encoding]::UTF8)

    # 写入相对路径指针文件
    $pointerPath = Join-Path $ToolRoot "output\latest-proxy-snapshot.json"
    $pointerObj = [PSCustomObject]@{
        LatestRelativePath = $relativeSnapPath
        Timestamp          = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    [System.IO.File]::WriteAllText($pointerPath, ($pointerObj | ConvertTo-Json), [System.Text.Encoding]::UTF8)

    # 3. 设置为直连
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0 -Type DWord -Force
    if ($props.PSObject.Properties['ProxyServer']) { Remove-ItemProperty -Path $regPath -Name ProxyServer -Force -ErrorAction SilentlyContinue }
    if ($props.PSObject.Properties['AutoConfigURL']) { Remove-ItemProperty -Path $regPath -Name AutoConfigURL -Force -ErrorAction SilentlyContinue }
    Set-ItemProperty -Path $regPath -Name AutoDetect -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

    Write-Host "`n[完成] 当前用户 WinINET 代理已成功重置为直连模式！" -ForegroundColor Green
    Write-Host "代理快照已保存至: $relativeSnapPath (可通过菜单 [6] 精确恢复)" -ForegroundColor Cyan
    return $true
}

function Restore-ProxyFromSnapshot {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot),
        [string]$ConfirmationToken = "",
        [switch]$Force
    )

    Write-Host "=======================================================================" -ForegroundColor Cyan
    Write-Host "                   从代理快照精确恢复 WinINET 代理配置                 " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan

    $snapshotDir = Join-Path $ToolRoot "output\snapshots"
    $pointerPath = Join-Path $ToolRoot "output\latest-proxy-snapshot.json"
    $selectedSnapshotFile = $null

    # 1. 尝试从指针获取相对路径
    if (Test-Path $pointerPath) {
        try {
            $pData = Get-Content -Path $pointerPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($pData -and $pData.LatestRelativePath) {
                $candidate = Join-Path (Join-Path $ToolRoot "output") $pData.LatestRelativePath
                if (Test-Path $candidate) {
                    $selectedSnapshotFile = $candidate
                }
            }
        } catch { }
    }

    # 2. 若指针缺失或不可用，自动扫描 Reason=ResetProxy 的最新快照
    if (-not $selectedSnapshotFile) {
        if (Test-Path $snapshotDir) {
            $matchedFiles = Get-ChildItem -Path $snapshotDir -Filter "ProxySnapshot-*.json" |
                            Sort-Object LastWriteTime -Descending
            foreach ($mf in $matchedFiles) {
                try {
                    $c = Get-Content -Path $mf.FullName -Raw | ConvertFrom-Json
                    if ($c.Reason -eq 'ResetProxy' -and $c.Settings) {
                        $selectedSnapshotFile = $mf.FullName
                        break
                    }
                } catch { }
            }
        }
    }

    if (-not $selectedSnapshotFile -or -not (Test-Path $selectedSnapshotFile)) {
        Write-Host "[错误] 未找到可用的有效代理备份快照！" -ForegroundColor Red
        return $false
    }

    Write-Host "找到代理恢复快照: $(Split-Path -Leaf $selectedSnapshotFile)" -ForegroundColor Yellow
    $snapData = Get-Content -Path $selectedSnapshotFile -Raw | ConvertFrom-Json

    if (-not $Force) {
        if ($ConfirmationToken -ne "RESTORE") {
            Write-Host "`n请输入精确确认指令 [RESTORE] 以继续，或按回车取消:" -ForegroundColor Yellow -NoNewline
            $inputVal = Read-Host
            if ($inputVal -ne "RESTORE") {
                Write-Host "操作已取消。" -ForegroundColor Green
                return $false
            }
        }
    }

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    if (-not $PSCmdlet.ShouldProcess($regPath, "从快照还原 WinINET 代理设置")) {
        return $false
    }

    $settings = $snapData.Settings
    foreach ($name in $settings.PSObject.Properties.Name) {
        $item = $settings.$name
        if ($item.Present) {
            $val = $item.Value
            if ($name -in @('ProxyEnable', 'AutoDetect')) {
                Set-ItemProperty -Path $regPath -Name $name -Value ([int]$val) -Type DWord -Force
            } else {
                Set-ItemProperty -Path $regPath -Name $name -Value ([string]$val) -Type String -Force
            }
            Write-Host "   - 恢复键值: $name -> $val" -ForegroundColor Green
        } else {
            Remove-ItemProperty -Path $regPath -Name $name -Force -ErrorAction SilentlyContinue
            Write-Host "   - 移除键值: $name (快照中不存在)" -ForegroundColor Yellow
        }
    }
    Write-Host "`n[完成] WinINET 代理配置已精确恢复！" -ForegroundColor Green
    return $true
}

Export-ModuleMember -Function @(
    'Save-NetworkSnapshot',
    'Invoke-SafeRepair',
    'Invoke-ReconnectAdapter',
    'Invoke-DeepReset',
    'Invoke-ResetProxyToDirect',
    'Restore-ProxyFromSnapshot'
)

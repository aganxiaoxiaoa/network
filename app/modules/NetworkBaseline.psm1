#Requires -Version 5.1
# ==============================================================================
# NetworkBaseline.psm1
# 便携网络只读诊断工具箱 - 健康基线保存与差异比对模块
# 严格遵循只读原则：仅做网络状态数据采集与比对，绝不提供任何系统配置恢复/改写能力
# 严禁任何注册表修改、服务启停、代理设置或网络重置操作
# ==============================================================================

Set-StrictMode -Version 2.0

function Get-BaselineStateSnapshot {
    [CmdletBinding()]
    param()

    # 1. IPv4 默认路由与网关
    $routeInfo = Get-DefaultRouteInfo
    $defGw = if ($routeInfo.HasDefaultRoute) { [string]$routeInfo.NextHop } else { $null }
    $routeMetric = if ($routeInfo.HasDefaultRoute) { [int]$routeInfo.RouteMetric } else { $null }
    $effMetric = if ($routeInfo.HasDefaultRoute) { [int]$routeInfo.EffectiveMetric } else { $null }

    # 2. IPv6 默认路由状态
    $nicIndex = if ($routeInfo.HasDefaultRoute) { [int]$routeInfo.InterfaceIndex } else { 0 }
    $v6Info = Get-IPv6Status -PreferredInterfaceIndex $nicIndex
    $v6HasDefault = [bool]$v6Info.HasDefaultRoute

    # 3. 活动物理网卡
    $adapter = Get-ActivePhysicalAdapter -PreferredInterfaceIndex $nicIndex
    $name = if ($adapter.Found) { [string]$adapter.Name } else { "" }
    $ifIndex = if ($adapter.Found) { [int]$adapter.InterfaceIndex } else { 0 }
    $ifGuid = if ($adapter.Found) { [string]$adapter.InterfaceGuid } else { "" }
    $mac = if ($adapter.Found) { [string]$adapter.MacAddress } else { "" }
    $desc = if ($adapter.Found) { [string]$adapter.InterfaceDescription } else { "" }
    $isHw = if ($adapter.Found) { [bool]$adapter.HardwareInterface } else { $false }
    $linkSpeed = if ($adapter.Found) { [string]$adapter.LinkSpeed } else { "" }

    # 4. IP 地址、前缀、DHCP、DNS
    $ipDetails = if ($adapter.Found) { Get-AdapterIpDetails -InterfaceIndex $ifIndex } else { Get-AdapterIpDetails -InterfaceIndex 0 }
    $ipv4Addr = if ($ipDetails.IPv4Address) { [string]$ipDetails.IPv4Address } else { "" }
    $dhcpEnabled = [bool]$ipDetails.DhcpEnabled
    $dnsServers = @($ipDetails.DnsServers)

    # 5. 电源管理 (只读)
    $pwr = if ($name) { Get-AdapterPowerManagementStatus -AdapterName $name } else { Get-AdapterPowerManagementStatus }
    $pwrSupported = [bool]$pwr.Supported
    $allowTurnOff = [string]$pwr.AllowTurnOffDevice

    # 6. 系统代理快照 (只读)
    $proxy = Get-ProxyStatus
    $proxyEnable = if ($proxy.WinInet) { [int]$proxy.WinInet.ProxyEnable } else { 0 }
    $proxyServer = if ($proxy.WinInet -and $proxy.WinInet.ProxyServer) { [string]$proxy.WinInet.ProxyServer } else { "" }
    $proxyOverride = if ($proxy.WinInet -and $proxy.WinInet.ProxyOverride) { [string]$proxy.WinInet.ProxyOverride } else { "" }
    $autoConfigUrl = if ($proxy.WinInet -and $proxy.WinInet.AutoConfigURL) { [string]$proxy.WinInet.AutoConfigURL } else { "" }

    # 7. 核心网络服务状态与启动类型
    $cfg = Get-ToolConfig
    $svcNames = if ($null -ne $cfg -and $cfg.Contains('CoreNetworkServices')) {
        @($cfg['CoreNetworkServices'])
    } else {
        @("Dhcp", "Dnscache", "nsi", "Wlansvc", "NlaSvc", "WinHttpAutoProxySvc")
    }
    $svcList = Get-NetworkServiceStatus -ServiceNames $svcNames
    $svcStartTypes = [ordered]@{}
    $svcStatuses = [ordered]@{}
    if ($svcList) {
        foreach ($s in $svcList) {
            $svcStartTypes[$s.Name] = [string]$s.StartType
            $svcStatuses[$s.Name] = [string]$s.Status
        }
    }

    # 8. 易变指标采集 (DHCP 租约、WLAN 信号、速率等)
    $dhcpLease = Get-DhcpLeaseInfo
    $dhcpRemMin = if ($dhcpLease.DhcpActive -and $null -ne $dhcpLease.RemainingMinutes) { [double]$dhcpLease.RemainingMinutes } else { $null }

    $wlanQ = Get-WlanLinkQuality
    $rxRate = if ($wlanQ.Available) { $wlanQ.ReceiveRate } else { $null }
    $txRate = if ($wlanQ.Available) { $wlanQ.TransmitRate } else { $null }
    $sigPct = if ($wlanQ.Available) { $wlanQ.SignalPercent } else { $null }
    $rssiEst = if ($wlanQ.Available) { $wlanQ.RssiEstimated } else { $null }

    # 组装结构化基线数据
    $snapshot = [ordered]@{
        Metadata = [ordered]@{
            Timestamp    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            ComputerName = $env:COMPUTERNAME
            OSVersion    = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
            ToolVersion  = "2.0-ReadOnly"
        }
        Stable = [ordered]@{
            InterfaceGuid        = $ifGuid
            MacAddress           = $mac
            InterfaceDescription = $desc
            HardwareInterface    = $isHw
            DhcpEnabled          = $dhcpEnabled
            DnsServers           = $dnsServers
            DefaultGateway       = $defGw
            ProxyEnable          = $proxyEnable
            ProxyServer          = $proxyServer
            ProxyOverride        = $proxyOverride
            AutoConfigURL        = $autoConfigUrl
            ServiceStartTypes    = $svcStartTypes
            IPv6HasDefaultRoute  = $v6HasDefault
        }
        Volatile = [ordered]@{
            IPv4Address          = $ipv4Addr
            DhcpRemainingMinutes = $dhcpRemMin
            LinkSpeed            = $linkSpeed
            ReceiveRate          = $rxRate
            TransmitRate         = $txRate
            SignalPercent        = $sigPct
            RssiEstimated        = $rssiEst
            RouteMetric          = $routeMetric
            EffectiveMetric      = $effMetric
            ServiceStatuses      = $svcStatuses
        }
    }

    return $snapshot
}

function Save-NetworkBaseline {
    [CmdletBinding()]
    param(
        [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot),
        [string]$BaselineDir = (Join-Path $ToolRoot "output\baseline"),
        [string]$PointerFileName = "latest.txt"
    )

    try {
        if (-not (Test-Path -LiteralPath $BaselineDir)) {
            New-Item -Path $BaselineDir -ItemType Directory -Force | Out-Null
        }

        Write-Host "正在采集当前网络配置与健康状态基线快照..." -ForegroundColor Yellow
        $snapshot = Get-BaselineStateSnapshot

        $ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
        $fileName = "baseline-$ts.json"
        $filePath = Join-Path $BaselineDir $fileName

        # 写入 JSON
        $jsonStr = ConvertTo-Json $snapshot -Depth 6
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($filePath, $jsonStr, $utf8Bom)

        # 写入指针文件 (严格便携要求：只写纯相对文件名，绝不写盘符与路径)
        $pointerPath = Join-Path $BaselineDir $PointerFileName
        [System.IO.File]::WriteAllText($pointerPath, $fileName, $utf8Bom)

        $relSaved = Join-Path "output\baseline" $fileName

        Write-Host "[成功] 健康基线已成功保存！" -ForegroundColor Green
        Write-Host "   - 基线文件: $relSaved" -ForegroundColor Cyan
        Write-Host "   - 指针更新: output\baseline\$PointerFileName -> $fileName" -ForegroundColor Gray
        Write-Host "   - 稳定项数: $(@($snapshot.Stable.Keys).Count) 个 | 易变参考项数: $(@($snapshot.Volatile.Keys).Count) 个" -ForegroundColor Gray

        return [PSCustomObject]@{
            Success          = $true
            RelativeFilePath = $relSaved
            FileName         = $fileName
            PointerFile      = $PointerFileName
            ExitCode         = 0
        }
    } catch {
        Write-Host "[错误] 保存基线失败: $($_.Exception.Message)" -ForegroundColor Red
        return [PSCustomObject]@{
            Success  = $false
            Error    = $_.Exception.Message
            ExitCode = 1
        }
    }
}

function Compare-NetworkBaseline {
    [CmdletBinding()]
    param(
        [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot),
        [string]$BaselineFile = $null,
        [string]$BaselineDir = (Join-Path $ToolRoot "output\baseline"),
        [string]$PointerFileName = "latest.txt"
    )

    $targetFile = $null
    $targetName = $null

    # 1. 解析目标基线文件路径
    if (-not [string]::IsNullOrWhiteSpace($BaselineFile)) {
        if (Test-Path -LiteralPath $BaselineFile) {
            $targetFile = (Resolve-Path -LiteralPath $BaselineFile).Path
            $targetName = [System.IO.Path]::GetFileName($targetFile)
        } else {
            $candidate = Join-Path $BaselineDir $BaselineFile
            if (Test-Path -LiteralPath $candidate) {
                $targetFile = (Resolve-Path -LiteralPath $candidate).Path
                $targetName = [System.IO.Path]::GetFileName($targetFile)
            } else {
                Write-Host "[错误] 指定基线文件不存在: $BaselineFile" -ForegroundColor Red
                return [PSCustomObject]@{
                    Success   = $false
                    ExitCode  = 1
                    Message   = "指定基线文件不存在: $BaselineFile"
                }
            }
        }
    } else {
        # 使用指针文件查找最近一份基线
        if (-not (Test-Path -LiteralPath $BaselineDir)) {
            Write-Host "[错误] 基线目录不存在: $BaselineDir，请先执行 SaveBaseline" -ForegroundColor Red
            return [PSCustomObject]@{
                Success  = $false
                ExitCode = 1
                Message  = "基线目录不存在: $BaselineDir"
            }
        }

        $pointerPath = Join-Path $BaselineDir $PointerFileName
        if (-not (Test-Path -LiteralPath $pointerPath)) {
            Write-Host "[错误] 未找到基线，请先执行 SaveBaseline" -ForegroundColor Red
            return [PSCustomObject]@{
                Success  = $false
                ExitCode = 1
                Message  = "未找到基线，请先执行 SaveBaseline"
            }
        }

        $pointerContent = [string]::Join("", (Get-Content -Path $pointerPath -ErrorAction SilentlyContinue)).Trim()
        if ([string]::IsNullOrWhiteSpace($pointerContent)) {
            Write-Host "[错误] 指针文件为空，未找到基线，请先执行 SaveBaseline" -ForegroundColor Red
            return [PSCustomObject]@{
                Success  = $false
                ExitCode = 1
                Message  = "指针文件为空，未找到基线"
            }
        }

        $candidate = Join-Path $BaselineDir $pointerContent
        if (-not (Test-Path -LiteralPath $candidate)) {
            Write-Host "[错误] 指针记录的基线文件不存在: $pointerContent，请先执行 SaveBaseline" -ForegroundColor Red
            return [PSCustomObject]@{
                Success  = $false
                ExitCode = 1
                Message  = "指针记录的基线文件不存在: $pointerContent"
            }
        }

        $targetFile = (Resolve-Path -LiteralPath $candidate).Path
        $targetName = $pointerContent
    }

    # 2. 读取并解析基线 JSON
    Write-Host "正在读取基线文件: $targetName..." -ForegroundColor Cyan
    $baselineJson = $null
    try {
        $raw = Get-Content -LiteralPath $targetFile -Raw -Encoding UTF8 -ErrorAction Stop
        $baselineJson = ConvertFrom-Json $raw -ErrorAction Stop
    } catch {
        Write-Host "[错误] 基线文件损坏，JSON 解析失败: $($_.Exception.Message)" -ForegroundColor Red
        return [PSCustomObject]@{
            Success  = $false
            ExitCode = 1
            Message  = "基线文件损坏，JSON 解析失败: $($_.Exception.Message)"
        }
    }

    # 3. 采集当前网络快照
    Write-Host "正在采集当前实时网络状态..." -ForegroundColor Cyan
    $currentSnapshot = Get-BaselineStateSnapshot

    # 4. 比对稳定字段与易变字段
    $cfg = Get-ToolConfig
    $stableKeys = @(
        "InterfaceGuid", "MacAddress", "InterfaceDescription", "HardwareInterface",
        "DhcpEnabled", "DnsServers", "DefaultGateway", "ProxyEnable",
        "ProxyServer", "ProxyOverride", "AutoConfigURL", "ServiceStartTypes",
        "IPv6HasDefaultRoute"
    )
    if ($null -ne $cfg -and $cfg.Contains('BaselineStableFields')) {
        $stableKeys = @($cfg['BaselineStableFields'])
    }

    $volatileKeys = @(
        "IPv4Address", "DhcpRemainingMinutes", "LinkSpeed", "ReceiveRate",
        "TransmitRate", "SignalPercent", "RssiEstimated", "RouteMetric",
        "EffectiveMetric", "ServiceStatuses"
    )
    if ($null -ne $cfg -and $cfg.Contains('BaselineVolatileFields')) {
        $volatileKeys = @($cfg['BaselineVolatileFields'])
    }

    $stableDiffs = [System.Collections.Generic.List[PSCustomObject]]::new()
    $volatileDiffs = [System.Collections.Generic.List[PSCustomObject]]::new()

    function Normalize-Val {
        param($v)
        if ($null -eq $v) { return "" }
        if ($v -is [System.Collections.IDictionary]) {
            $pairs = @()
            foreach ($k in ($v.Keys | Sort-Object)) {
                $pairs += "$k=$($v[$k])"
            }
            return $pairs -join ", "
        }
        if ($v -is [PSCustomObject]) {
            $pairs = @()
            foreach ($p in ($v.PSObject.Properties | Sort-Object Name)) {
                $pairs += "$($p.Name)=$($p.Value)"
            }
            return $pairs -join ", "
        }
        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
            $items = @($v) | ForEach-Object { [string]$_ }
            return ($items | Sort-Object) -join "; "
        }
        return [string]$v
    }

    # 比对稳定字段
    foreach ($k in $stableKeys) {
        $baseVal = if ($baselineJson.Stable.PSObject.Properties[$k]) { $baselineJson.Stable.$k } else { $null }
        $currVal = if ($currentSnapshot.Stable.Contains($k)) { $currentSnapshot.Stable[$k] } else { $null }

        $normBase = Normalize-Val $baseVal
        $normCurr = Normalize-Val $currVal

        if ($normBase -ne $normCurr) {
            $stableDiffs.Add([PSCustomObject]@{
                Field    = $k
                Baseline = $normBase
                Current  = $normCurr
                Category = "Stable"
            })
        }
    }

    # 比对易变字段
    foreach ($k in $volatileKeys) {
        $baseVal = if ($baselineJson.Volatile.PSObject.Properties[$k]) { $baselineJson.Volatile.$k } else { $null }
        $currVal = if ($currentSnapshot.Volatile.Contains($k)) { $currentSnapshot.Volatile[$k] } else { $null }

        $normBase = Normalize-Val $baseVal
        $normCurr = Normalize-Val $currVal

        if ($normBase -ne $normCurr) {
            $volatileDiffs.Add([PSCustomObject]@{
                Field    = $k
                Baseline = $normBase
                Current  = $normCurr
                Category = "Volatile"
            })
        }
    }

    # 5. 落盘比对明细至 logs
    $logsDir = Join-Path $ToolRoot "logs"
    if (-not (Test-Path -LiteralPath $logsDir)) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    }
    $tsLog = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $logFilePath = Join-Path $logsDir "baseline_compare_$tsLog.log"

    $logLines = [System.Collections.Generic.List[string]]::new()
    $logLines.Add("================================================================================")
    $logLines.Add("Windows 10/11 便携网络诊断工具箱 - 健康基线差异比对报告")
    $logLines.Add("基线文件: $targetName | 比对时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $logLines.Add("基线采集时间: $($baselineJson.Metadata.Timestamp) | 主机名: $($baselineJson.Metadata.ComputerName)")
    $logLines.Add("================================================================================")

    $logLines.Add("【一、稳定字段差异 (潜在异常判定依据)】:")
    if (@($stableDiffs).Count -eq 0) {
        $logLines.Add("   稳定字段无差异。")
    } else {
        foreach ($d in $stableDiffs) {
            $logLines.Add("   * 字段: $($d.Field)")
            $logLines.Add("       基线值: $($d.Baseline)")
            $logLines.Add("       当前值: $($d.Current)")
        }
    }

    $logLines.Add("`n【二、易变字段变化 (参考信息，不视为异常)】:")
    if (@($volatileDiffs).Count -eq 0) {
        $logLines.Add("   易变字段无变化。")
    } else {
        foreach ($d in $volatileDiffs) {
            $logLines.Add("   * 字段: $($d.Field)")
            $logLines.Add("       基线值: $($d.Baseline)")
            $logLines.Add("       当前值: $($d.Current)")
        }
    }

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($logFilePath, $logLines, $utf8Bom)

    # 6. 控制台呈现差异摘要
    Write-Host "`n=======================================================================" -ForegroundColor Cyan
    Write-Host "                网络健康基线差异比对结果                              " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan
    Write-Host " 基线文件: $targetName (采集于 $($baselineJson.Metadata.Timestamp))" -ForegroundColor Gray
    Write-Host " 比对明细已记录至: logs\baseline_compare_$tsLog.log" -ForegroundColor Gray

    $exitCode = 0
    Write-Host "`n[核心稳定字段比对结果]:" -ForegroundColor Yellow
    if (@($stableDiffs).Count -eq 0) {
        Write-Host "   [√] 稳定字段无差异 (网卡Guid/MAC/网关/DNS/代理/服务启动类型完全一致)" -ForegroundColor Green
        $exitCode = 0
    } else {
        $exitCode = 2
        Write-Host "   [!] 发现 $(@($stableDiffs).Count) 项核心稳定字段差异 (潜在网络异常):" -ForegroundColor Red
        foreach ($d in $stableDiffs) {
            Write-Host "   - 字段 [$($d.Field)]:" -ForegroundColor Yellow
            Write-Host "       基线值 -> $($d.Baseline)" -ForegroundColor Cyan
            Write-Host "       当前值 -> $($d.Current)" -ForegroundColor Magenta
        }
    }

    Write-Host "`n[易变参考信息 (动态状态变化，不视为异常)]:" -ForegroundColor Gray
    if (@($volatileDiffs).Count -eq 0) {
        Write-Host "   - 易变字段无变化" -ForegroundColor Gray
    } else {
        foreach ($d in $volatileDiffs) {
            Write-Host "   - [$($d.Field)]: 基线 ($($d.Baseline)) -> 当前 ($($d.Current))" -ForegroundColor Gray
        }
    }

    Write-Host "=======================================================================" -ForegroundColor Cyan
    Write-Host "退出码判定: $exitCode (0=稳定字段无差异, 2=发现稳定字段差异, 1=执行错误)" -ForegroundColor Gray

    return [PSCustomObject]@{
        Success          = $true
        ExitCode         = $exitCode
        BaselineFileName = $targetName
        StableDiffCount  = @($stableDiffs).Count
        StableDiffs      = @($stableDiffs)
        VolatileDiffs    = @($volatileDiffs)
        LogFile          = $logFilePath
    }
}

Export-ModuleMember -Function @(
    'Save-NetworkBaseline',
    'Compare-NetworkBaseline'
)

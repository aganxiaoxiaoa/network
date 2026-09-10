# ==============================================================================
# NetworkHealth.psm1
# 便携网络只读诊断工具箱 - 纯只读健康状态探测模块
# 严格遵循只读原则：仅发起外发 TCP 探测与 ICMP Ping，不改动系统状态与协议栈
# ==============================================================================

Set-StrictMode -Version 2.0

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
        if (@($parts).Count -ne 2) { continue }
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
        $dnsRes = @(Resolve-DnsName -Name $Domain -Type A -QuickTimeout -ErrorAction Stop)
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

function Start-LinkSampler {
    [CmdletBinding()]
    param(
        [int]$IntervalSeconds = 2,
        [int]$DurationMinutes = 60,
        [string]$OutputPath = $null
    )

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $outDir = 'E:\Network-Recovery-USB\output\watch'
        if (-not (Test-Path -LiteralPath $outDir)) {
            [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
        }
        $fileTimestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $OutputPath = Join-Path $outDir "link-sample-$fileTimestamp.csv"
    } else {
        $parentDir = [System.IO.Path]::GetDirectoryName($OutputPath)
        if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
            [System.IO.Directory]::CreateDirectory($parentDir) | Out-Null
        }
    }

    $headers = @(
        'Timestamp',
        'AdapterStatus',
        'MediaConnectionState',
        'LinkSpeed',
        'ReceivedUnicastPackets',
        'SentUnicastPackets',
        'ReceivedPacketErrors',
        'ReceivedDiscardedPackets',
        'OutboundPacketErrors',
        'OutboundDiscardedPackets',
        'RxDelta',
        'TxDelta',
        'GatewayIPv4',
        'GatewayArpState',
        'GatewayPingSuccessCount',
        'GatewayPingAvgMs',
        'DefaultRouteIfIndex',
        'ProfileName',
        'IPv4Connectivity'
    )
    $headerLine = $headers -join ','
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, "$headerLine`n", $utf8NoBom)

    Write-Host "[Start-LinkSampler] 采样器已启动: Interval=${IntervalSeconds}s, Duration=${DurationMinutes}m" -ForegroundColor Green
    Write-Host "[Start-LinkSampler] 输出目标文件: $OutputPath" -ForegroundColor Green
    Write-Host "[Start-LinkSampler] 纯只读采样模式，按 Ctrl+C 可随时停止..." -ForegroundColor Gray

    $startTime = Get-Date
    $endTime = if ($DurationMinutes -gt 0) { $startTime.AddMinutes($DurationMinutes) } else { [datetime]::MaxValue }
    $prevRx = $null
    $prevTx = $null
    $sampleIndex = 0

    while ((Get-Date) -lt $endTime) {
        $sampleIndex++
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')

        # 1. AdapterStatus / MediaConnectionState / LinkSpeed
        $adapterStatus = 'ERROR'
        $mediaConnectionState = 'ERROR'
        $linkSpeed = 'ERROR'
        $nicName = $null
        try {
            $nic = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.InterfaceDescription -match 'MT7922' } | Select-Object -First 1
            if ($nic) {
                $nicName = $nic.Name
                $adapterStatus = if ($null -ne $nic.Status) { $nic.Status.ToString() } else { 'ERROR' }
                $mediaConnectionState = if ($null -ne $nic.MediaConnectionState) { $nic.MediaConnectionState.ToString() } else { 'ERROR' }
                $linkSpeed = if ($null -ne $nic.LinkSpeed) { $nic.LinkSpeed.ToString() } else { 'ERROR' }
            }
        } catch {
            $adapterStatus = 'ERROR'
            $mediaConnectionState = 'ERROR'
            $linkSpeed = 'ERROR'
        }

        # 2. Received*/Sent*/Outbound*
        $rxUnicast = 'ERROR'
        $txUnicast = 'ERROR'
        $rxErrors  = 'ERROR'
        $rxDiscard = 'ERROR'
        $txErrors  = 'ERROR'
        $txDiscard = 'ERROR'
        try {
            if ($nicName) {
                $stats = Get-NetAdapterStatistics -Name $nicName -ErrorAction Stop
                $rxUnicast = if ($null -ne $stats.ReceivedUnicastPackets) { $stats.ReceivedUnicastPackets } else { 'ERROR' }
                $txUnicast = if ($null -ne $stats.SentUnicastPackets) { $stats.SentUnicastPackets } else { 'ERROR' }
                $rxErrors  = if ($null -ne $stats.ReceivedPacketErrors) { $stats.ReceivedPacketErrors } else { 'ERROR' }
                $rxDiscard = if ($null -ne $stats.ReceivedDiscardedPackets) { $stats.ReceivedDiscardedPackets } else { 'ERROR' }
                $txErrors  = if ($null -ne $stats.OutboundPacketErrors) { $stats.OutboundPacketErrors } else { 'ERROR' }
                $txDiscard = if ($null -ne $stats.OutboundDiscardedPackets) { $stats.OutboundDiscardedPackets } else { 'ERROR' }
            }
        } catch {
            $rxUnicast = 'ERROR'; $txUnicast = 'ERROR'; $rxErrors = 'ERROR'; $rxDiscard = 'ERROR'; $txErrors = 'ERROR'; $txDiscard = 'ERROR'
        }

        # 3. RxDelta / TxDelta
        if ($prevRx -eq $null -or $rxUnicast -eq 'ERROR') {
            $rxDelta = 0
        } else {
            $rxDelta = [int64]$rxUnicast - [int64]$prevRx
        }
        if ($prevTx -eq $null -or $txUnicast -eq 'ERROR') {
            $txDelta = 0
        } else {
            $txDelta = [int64]$txUnicast - [int64]$prevTx
        }
        if ($rxUnicast -ne 'ERROR') { $prevRx = [int64]$rxUnicast }
        if ($txUnicast -ne 'ERROR') { $prevTx = [int64]$txUnicast }

        # 4. GatewayIPv4 & DefaultRouteIfIndex
        $gw = 'ERROR'
        $ifIndex = 'ERROR'
        try {
            $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
            if ($route) {
                if ($null -ne $route.NextHop -and $route.NextHop -ne '') { $gw = $route.NextHop }
                if ($null -ne $route.ifIndex) { $ifIndex = $route.ifIndex }
            }
        } catch {
            $gw = 'ERROR'
            $ifIndex = 'ERROR'
        }

        # 5. GatewayArpState
        $arpState = 'ERROR'
        try {
            if ($gw -ne 'ERROR' -and $gw) {
                $neighbor = Get-NetNeighbor -IPAddress $gw -ErrorAction Stop | Select-Object -First 1
                if ($neighbor -and $neighbor.State) {
                    $arpState = $neighbor.State.ToString()
                }
            }
        } catch {
            $arpState = 'ERROR'
        }

        # 6. GatewayPingSuccessCount & GatewayPingAvgMs
        $pingSuccess = 'ERROR'
        $pingAvg = 'ERROR'
        try {
            if ($gw -ne 'ERROR' -and $gw) {
                $pings = @(Test-Connection -ComputerName $gw -Count 3 -ErrorAction SilentlyContinue)
                $pingSuccess = $pings.Count
                if ($pingSuccess -gt 0) {
                    $avgMs = ($pings | Measure-Object -Property ResponseTime -Average).Average
                    $pingAvg = [math]::Round($avgMs, 2)
                } else {
                    $pingAvg = 0
                }
            }
        } catch {
            $pingSuccess = 'ERROR'
            $pingAvg = 'ERROR'
        }

        # 7. ProfileName & IPv4Connectivity
        $profName = 'ERROR'
        $v4Conn   = 'ERROR'
        try {
            $profile = if ($ifIndex -ne 'ERROR' -and $ifIndex) {
                Get-NetConnectionProfile -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1
            } else { $null }
            if (-not $profile) {
                $profile = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($profile) {
                if ($profile.Name) { $profName = $profile.Name }
                if ($profile.IPv4Connectivity) { $v4Conn = $profile.IPv4Connectivity.ToString() }
            }
        } catch {
            $profName = 'ERROR'
            $v4Conn = 'ERROR'
        }

        # Format CSV row
        $row = @(
            $timestamp,
            $adapterStatus,
            $mediaConnectionState,
            $linkSpeed,
            $rxUnicast,
            $txUnicast,
            $rxErrors,
            $rxDiscard,
            $txErrors,
            $txDiscard,
            $rxDelta,
            $txDelta,
            $gw,
            $arpState,
            $pingSuccess,
            $pingAvg,
            $ifIndex,
            $profName,
            $v4Conn
        ) -join ','

        [System.IO.File]::AppendAllText($OutputPath, "$row`n", $utf8NoBom)

        # 控制台打印一行简短摘要
        Write-Host ("[{0}] #{1:D3} | Status={2} ({3}) | RxDelta=+{4} TxDelta=+{5} | GW={6} ARP={7} Ping={8}/3 ({9}ms) | Profile={10} ({11})" -f `
            $timestamp, $sampleIndex, $adapterStatus, $mediaConnectionState, $rxDelta, $txDelta, $gw, $arpState, $pingSuccess, $pingAvg, $profName, $v4Conn) -ForegroundColor Cyan

        if ((Get-Date) -ge $endTime) { break }
        if ($IntervalSeconds -gt 0) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }

    Write-Host "[Start-LinkSampler] 采样完成，共采集 $sampleIndex 轮，输出文件: $OutputPath" -ForegroundColor Green
    return $OutputPath
}

Export-ModuleMember -Function @(
    'Test-DynamicGateway',
    'Test-RawTcpTargets',
    'Test-DnsResolution',
    'Start-LinkSampler'
)


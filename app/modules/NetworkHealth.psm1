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

Export-ModuleMember -Function @(
    'Test-DynamicGateway',
    'Test-RawTcpTargets',
    'Test-DnsResolution'
)

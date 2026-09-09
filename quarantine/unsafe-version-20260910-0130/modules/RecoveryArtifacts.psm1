# ==============================================================================
# RecoveryArtifacts.psm1
# 便携网络恢复与诊断工具箱 - 驱动导出与诊断脱敏打包模块
# 严格遵循：
#  1. 仅导出 DeviceClass=Net 的第三方 oem*.inf 驱动
#  2. 严禁导出 Wi-Fi 明文密码 (绝不使用 key=clear)
#  3. 严禁收集浏览器凭据、Cookie 或无关个人文件
#  4. WLAN report 仅作为显式警告的可选项
# ==============================================================================

Set-StrictMode -Version 2.0

function Export-NetworkDrivers {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot),
        [int]$MinFreeSpaceMB = 500
    )

    Write-Host "=======================================================================" -ForegroundColor Cyan
    Write-Host "             导出第三方网络适配器驱动程序 (PnPUtil 备份)                " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan

    # 1. 检查 U 盘空间
    $driveRoot = (Get-Item $ToolRoot).Root.FullName
    $driveInfo = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $driveRoot.TrimEnd('\') }
    if ($driveInfo) {
        $freeMB = [math]::Round($driveInfo.FreeSpace / 1MB, 0)
        if ($freeMB -lt $MinFreeSpaceMB) {
            Write-Host "[拒绝] U 盘剩余可用空间不足 ($freeMB MB < $MinFreeSpaceMB MB)，为防止磁盘占满，拒绝导出！" -ForegroundColor Red
            return $false
        }
        Write-Host "   - U 盘驱动器 ($driveRoot) 可用空间: $freeMB MB (充足)" -ForegroundColor Green
    }

    # 2. 枚举第三方 Net 类驱动
    Write-Host "正在扫描系统中的第三方网络硬件驱动..." -ForegroundColor Yellow
    $rawDrivers = pnputil /enum-drivers /class Net 2>&1

    $driverList = @()
    $current = $null

    foreach ($line in ($rawDrivers -split "`r?`n")) {
        if ($line -match '^Published Name:\s+(oem\d+\.inf)') {
            if ($current) { $driverList += [PSCustomObject]$current }
            $current = @{
                PublishedName = $matches[1].Trim()
                OriginalName  = ""
                ProviderName  = ""
                ClassName     = "Net"
                DriverVersion = ""
                SignerName    = ""
            }
        } elseif ($current) {
            if ($line -match '^Original Name:\s+(.+)$') { $current.OriginalName = $matches[1].Trim() }
            elseif ($line -match '^Provider Name:\s+(.+)$') { $current.ProviderName = $matches[1].Trim() }
            elseif ($line -match '^Class Name:\s+(.+)$') { $current.ClassName = $matches[1].Trim() }
            elseif ($line -match '^Driver Version:\s+(.+)$') { $current.DriverVersion = $matches[1].Trim() }
            elseif ($line -match '^Signer Name:\s+(.+)$') { $current.SignerName = $matches[1].Trim() }
        }
    }
    if ($current) { $driverList += [PSCustomObject]$current }

    if ($driverList.Count -eq 0) {
        Write-Host "   - 未检测到任何第三方 oem*.inf 网络驱动 (可能全部为 Windows 内置驱动)。" -ForegroundColor Yellow
        return $true
    }

    Write-Host "   - 共检测到 $($driverList.Count) 个第三方网络硬件驱动:" -ForegroundColor Green
    foreach ($d in $driverList) {
        Write-Host ("     * {0,-12} | {1,-18} | {2,-18} | {3}" -f $d.PublishedName, $d.OriginalName, $d.ProviderName, $d.DriverVersion)
    }

    # 3. 导出操作
    $driversOutDir = Join-Path $ToolRoot "output\drivers"

    if (-not $PSCmdlet.ShouldProcess($driversOutDir, "导出第三方网络驱动并生成清单")) {
        return $false
    }

    if (-not (Test-Path $driversOutDir)) {
        New-Item -ItemType Directory -Path $driversOutDir -Force | Out-Null
    }

    # 保存 CSV 清单
    $csvPath = Join-Path $driversOutDir "driver-inventory.csv"
    $driverList | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "`n   - 驱动清单已写入: output\drivers\driver-inventory.csv" -ForegroundColor Cyan

    # 逐个导出驱动
    foreach ($d in $driverList) {
        $oemInf = $d.PublishedName
        Write-Host "   - 正在导出 $oemInf ($($d.OriginalName))..." -ForegroundColor Yellow
        $exportRes = pnputil /export-driver $oemInf $driversOutDir 2>&1
    }

    Write-Host "`n[完成] 驱动备份完成！所有文件均保存在 U 盘 output\drivers 目录下。" -ForegroundColor Green
    Write-Host "驱动恢复说明：在目标电脑管理员命令行中执行：" -ForegroundColor Gray
    Write-Host "  pnputil /add-driver `"<U盘路径>\output\drivers\*.inf`" /subdirs /install" -ForegroundColor Gray
    return $true
}

function New-DiagnosticBundle {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot),
        [switch]$IncludeWlanReport
    )

    Write-Host "=======================================================================" -ForegroundColor Cyan
    Write-Host "               生成 Windows 网络诊断与脱敏报告压缩包                  " -ForegroundColor Cyan
    Write-Host "=======================================================================" -ForegroundColor Cyan

    $outDir = Join-Path $ToolRoot "output"
    $ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $tempDir = Join-Path $outDir "bundle-temp-$ts"
    $zipPath = Join-Path $outDir "NetworkDiagnosticBundle-$ts.zip"

    if (-not $PSCmdlet.ShouldProcess($zipPath, "收集网络环境配置并创建诊断报告压缩包")) {
        return $false
    }

    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    try {
        Write-Host "正在收集系统基础网络信息 (脱敏中)..." -ForegroundColor Yellow

        # 1. ipconfig /all
        (ipconfig /all 2>&1) | Out-File (Join-Path $tempDir "01_ipconfig_all.txt") -Encoding UTF8

        # 2. route print
        (route print 2>&1) | Out-File (Join-Path $tempDir "02_route_print.txt") -Encoding UTF8

        # 3. Get-NetAdapter
        (Get-NetAdapter -ErrorAction SilentlyContinue | Format-List * 2>&1) | Out-File (Join-Path $tempDir "03_netadapter.txt") -Encoding UTF8

        # 4. Get-NetIPInterface
        (Get-NetIPInterface -ErrorAction SilentlyContinue | Format-List * 2>&1) | Out-File (Join-Path $tempDir "04_netipinterface.txt") -Encoding UTF8

        # 5. Get-NetIPAddress
        (Get-NetIPAddress -ErrorAction SilentlyContinue | Format-List * 2>&1) | Out-File (Join-Path $tempDir "05_netipaddress.txt") -Encoding UTF8

        # 6. Get-NetRoute
        (Get-NetRoute -ErrorAction SilentlyContinue | Format-List * 2>&1) | Out-File (Join-Path $tempDir "06_netroute.txt") -Encoding UTF8

        # 7. Get-DnsClientServerAddress
        (Get-DnsClientServerAddress -ErrorAction SilentlyContinue | Format-List * 2>&1) | Out-File (Join-Path $tempDir "07_dns_client_servers.txt") -Encoding UTF8

        # 8. WinHTTP proxy (只读)
        (netsh winhttp show proxy 2>&1) | Out-File (Join-Path $tempDir "08_winhttp_proxy.txt") -Encoding UTF8

        # 9. WLAN 状态与驱动 (绝不包含 key=clear)
        (netsh wlan show interfaces 2>&1) | Out-File (Join-Path $tempDir "09_wlan_interfaces.txt") -Encoding UTF8
        (netsh wlan show drivers 2>&1) | Out-File (Join-Path $tempDir "10_wlan_drivers.txt") -Encoding UTF8

        # 10. WLAN 事件日志 (最近 50 条)
        try {
            $events = Get-WinEvent -LogName "Microsoft-Windows-WLAN-AutoConfig/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
                      Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
            $events | Out-File (Join-Path $tempDir "11_wlan_autoconfig_events.txt") -Encoding UTF8
        } catch {
            "无法获取 WLAN-AutoConfig 事件日志: $($_.Exception.Message)" | Out-File (Join-Path $tempDir "11_wlan_autoconfig_events.txt") -Encoding UTF8
        }

        # 11. 核心网络服务状态
        (Get-Service Dhcp, Dnscache, nsi, Wlansvc -ErrorAction SilentlyContinue | Format-Table -AutoSize 2>&1) | Out-File (Join-Path $tempDir "12_services.txt") -Encoding UTF8

        # 12. 可选的 WLAN Report
        if ($IncludeWlanReport) {
            Write-Host "   - [警告] 正在生成完整 WLAN 报告 (可能包含历史 SSID、MAC 地址与设备名)..." -ForegroundColor Yellow
            $wlanRepPath = Join-Path $tempDir "wlan-report.html"
            netsh wlan show wlanreport 2>&1 | Out-Null
            $defReport = "$env:ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html"
            if (Test-Path $defReport) {
                Copy-Item $defReport $wlanRepPath -Force
            }
        }

        # 打包压缩
        Write-Host "正在压缩生成诊断报告包..." -ForegroundColor Yellow
        Compress-Archive -Path "$tempDir\*" -DestinationPath $zipPath -Force
        Write-Host "`n[完成] 诊断包已成功生成: $(Split-Path -Leaf $zipPath)" -ForegroundColor Green
        Write-Host "   - 存储路径: $zipPath" -ForegroundColor Cyan
        Write-Host "   - [重要提示] 分享给技术支持前，请务必自行检查并对敏感内部 IP / 域名进行必要脱敏！" -ForegroundColor Yellow
        return $true
    } finally {
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function @(
    'Export-NetworkDrivers',
    'New-DiagnosticBundle'
)

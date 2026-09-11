#Requires -Version 5.1
# ==============================================================================
# Invoke-SafeRecoveryTests.ps1
# 安全恢复模块的纯函数行为测试 + 永久红线静态自检
#
# 本测试**不接触真实网络**：全部使用伪造对象，不调用 netsh / ipconfig 的写操作。
# 可在 Windows PowerShell 5.1 与 PowerShell 7 下运行：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-SafeRecoveryTests.ps1
# 退出码: 0 全部通过 / 1 存在失败
# ==============================================================================

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

$TestsDir = $PSScriptRoot
$ToolRoot = Split-Path -Parent $TestsDir
$AppDir = Join-Path $ToolRoot 'app'
$ModulesDir = Join-Path $AppDir 'modules'

Import-Module (Join-Path $ModulesDir 'SafeRecoveryObservation.psm1') -Force
Import-Module (Join-Path $ModulesDir 'SafeRecoveryActions.psm1') -Force

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][bool]$Condition)
    if ($Condition) {
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
    }
}

function Assert-Throws {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Action)
    try {
        & $Action | Out-Null
        $script:Failed++
        Write-Host "  FAIL  $Name (预期抛错但未抛错)" -ForegroundColor Red
    } catch {
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
}

function New-FakeAdapter {
    param(
        [string]$Name = 'WLAN',
        $InterfaceType = 71,
        $PhysicalMediaType = 'Native 802.11',
        [bool]$Virtual = $false,
        [bool]$HardwareInterface = $true,
        [string]$InterfaceGuid = '{11111111-1111-1111-1111-111111111111}',
        [int]$InterfaceIndex = 12
    )
    return [pscustomobject]@{
        Name              = $Name
        InterfaceType     = $InterfaceType
        PhysicalMediaType = $PhysicalMediaType
        Virtual           = $Virtual
        HardwareInterface = $HardwareInterface
        InterfaceGuid     = $InterfaceGuid
        InterfaceIndex    = $InterfaceIndex
    }
}

function New-FakeState {
    param(
        [string]$MediaConnectionState = 'Connected',
        $WlanProfile = '701',
        $ConnectedProfile = '701',
        $IPv4Address = '192.168.0.103',
        $HasDefaultRoute = $true,
        $DhcpEnabled = $true
    )
    return [pscustomobject]@{
        MediaConnectionState = $MediaConnectionState
        WlanProfile          = $WlanProfile
        ConnectedProfile     = $ConnectedProfile
        IPv4Address          = $IPv4Address
        HasDefaultRoute      = $HasDefaultRoute
        DhcpEnabled          = $DhcpEnabled
    }
}

Write-Host "`n[1] 配置白名单与代码级硬编码上界" -ForegroundColor Cyan
$config = Get-SafeRecoveryConfig -AppDir $AppDir
Assert-True '配置白名单为 701/702' ((@($config.AllowedProfiles) -join ',') -eq '701,702')
Assert-True '代码级硬编码白名单为 701/702' (((Get-SafeRecoveryHardCodedAllowedProfile) -join ',') -eq '701,702')
Assert-True '确认令牌为 YES' ([string]$config.ConfirmationToken -eq 'YES')
Assert-Throws '编辑配置扩大白名单会被拒绝' {
    Assert-SafeRecoveryConfig -Config @{
        AllowedProfiles = @('Guest-WiFi'); PrimaryProfile = 'Guest-WiFi'; FallbackProfile = 'Guest-WiFi'
        ConnectTimeoutSeconds = 20; DhcpAutoWaitSeconds = 8; DhcpWaitSeconds = 30
        PollIntervalMilliseconds = 1000; GatewayPingCount = 2; ConfirmationToken = 'YES'; LogSubDirectory = 'logs'
    }
}
Assert-Throws '空白名单会被拒绝' { Assert-SafeRecoveryConfig -Config @{ AllowedProfiles = @(); PrimaryProfile = '701'; FallbackProfile = '702' } }
Assert-Throws '注入式配置文件名会被拒绝' { Assert-SafeRecoveryConfig -Config @{ AllowedProfiles = @('701 & calc'); PrimaryProfile = '701 & calc'; FallbackProfile = '701 & calc' } }
Assert-Throws '空确认令牌会被拒绝' {
    Assert-SafeRecoveryConfig -Config @{
        AllowedProfiles = @('701'); PrimaryProfile = '701'; FallbackProfile = '701'
        ConnectTimeoutSeconds = 20; DhcpAutoWaitSeconds = 8; DhcpWaitSeconds = 30
        PollIntervalMilliseconds = 1000; GatewayPingCount = 2; ConfirmationToken = ''; LogSubDirectory = 'logs'
    }
}

Write-Host "`n[2] 尝试顺序" -ForegroundColor Cyan
Assert-True '默认顺序 701 -> 702' (((Get-SafeRecoveryProfileOrder -Config $config) -join ',') -eq '701,702')
Assert-True '指定 702 时顺序 702 -> 701' (((Get-SafeRecoveryProfileOrder -Config $config -PreferredProfile '702') -join ',') -eq '702,701')
Assert-Throws '白名单外的目标会被拒绝' { Get-SafeRecoveryProfileOrder -Config $config -PreferredProfile '888' }

Write-Host "`n[3] 无线网卡识别 (0 张或多张必须中止)" -ForegroundColor Cyan
$wifiByType = New-FakeAdapter -InterfaceType 71 -PhysicalMediaType 'Unspecified'
$wifiByMedia = New-FakeAdapter -Name 'Wi-Fi 2' -InterfaceType 6 -PhysicalMediaType 'Native 802.11' -InterfaceGuid '{22222222-2222-2222-2222-222222222222}'
$wifiByNumericMedium = [pscustomobject]@{ Name = 'Wi-Fi 3'; InterfaceType = 6; NdisPhysicalMedium = 9; Virtual = $false; HardwareInterface = $true; InterfaceGuid = '{33333333-3333-3333-3333-333333333333}' }
$ethernet = New-FakeAdapter -Name 'Ethernet' -InterfaceType 6 -PhysicalMediaType '802.3' -InterfaceGuid '{44444444-4444-4444-4444-444444444444}'
$virtual = New-FakeAdapter -Name 'vEthernet' -Virtual $true -InterfaceGuid '{55555555-5555-5555-5555-555555555555}'
$softAp = New-FakeAdapter -Name 'SoftAP' -HardwareInterface $false -InterfaceGuid '{66666666-6666-6666-6666-666666666666}'

Assert-True 'ifType 71 识别为无线' (Test-SafeRecoveryIsWirelessAdapter -Adapter $wifiByType)
Assert-True '字符串 Native 802.11 识别为无线' (Test-SafeRecoveryIsWirelessAdapter -Adapter $wifiByMedia)
Assert-True '数值型 NdisPhysicalMedium=9 识别为无线' (Test-SafeRecoveryIsWirelessAdapter -Adapter $wifiByNumericMedium)
Assert-True '以太网不被识别为无线' (-not (Test-SafeRecoveryIsWirelessAdapter -Adapter $ethernet))
Assert-True '虚拟网卡被排除' (-not (Test-SafeRecoveryIsWirelessAdapter -Adapter $virtual))
Assert-True '非硬件接口被排除' (-not (Test-SafeRecoveryIsWirelessAdapter -Adapter $softAp))
Assert-True '缺少属性的对象判为非无线且不抛错' (-not (Test-SafeRecoveryIsWirelessAdapter -Adapter ([pscustomobject]@{ Name = 'X' })))
Assert-True '候选筛选只保留无线网卡' ((Select-SafeRecoveryWlanCandidate -Adapter @($wifiByType, $wifiByMedia, $ethernet, $virtual, $softAp)).Count -eq 2)
Assert-True 'GUID 过滤忽略大括号差异' ((Select-SafeRecoveryWlanCandidate -Adapter @($wifiByType, $wifiByMedia) -ExpectedInterfaceGuid '11111111-1111-1111-1111-111111111111').Count -eq 1)
# 空结果按 PowerShell 枚举语义会退化为 $null，调用方必须用 @() 包裹 (见模块调用契约)
Assert-True 'GUID 过滤不能引入非无线网卡' (@(Select-SafeRecoveryWlanCandidate -Adapter @($wifiByType, $ethernet) -ExpectedInterfaceGuid '{44444444-4444-4444-4444-444444444444}').Count -eq 0)
Assert-True '全部为非无线时候选为空' (@(Select-SafeRecoveryWlanCandidate -Adapter @($ethernet, $virtual)).Count -eq 0)
Assert-True '空输入的配置文件解析结果为空' (@(ConvertFrom-SafeRecoveryProfileList -Output '').Count -eq 0)
Assert-True '空输入的接口解析结果为空' (@(ConvertFrom-SafeRecoveryWlanInterface -Output '').Count -eq 0)

Write-Host "`n[4] netsh 输出解析 (多语言，且绝不采集 BSSID)" -ForegroundColor Cyan
$profilesEn = "Profiles on interface WLAN:`n`nGroup policy profiles (read only)`n---------------------------------`n    <None>`n`nUser profiles`n-------------`n    All User Profile     : 701`n    All User Profile     : 702`n    All User Profile     : CMCC-Home`n"
$profilesZh = "接口 WLAN 上的配置文件:`n`n组策略配置文件(只读)`n---------------------------------`n    <无>`n`n用户配置文件`n-------------`n    所有用户配置文件     : 701`n    所有用户配置文件     : 702`n"
$parsedEn = @(ConvertFrom-SafeRecoveryProfileList -Output $profilesEn)
$parsedZh = @(ConvertFrom-SafeRecoveryProfileList -Output $profilesZh)
Assert-True '英文配置文件列表解析出 3 项' ($parsedEn.Count -eq 3 -and $parsedEn -contains '701' -and $parsedEn -contains '702')
Assert-True '中文配置文件列表解析出 701/702' ($parsedZh.Count -eq 2 -and $parsedZh -contains '701' -and $parsedZh -contains '702')
Assert-True '标题行未被误判为配置文件' ($parsedEn -notcontains 'WLAN' -and $parsedZh -notcontains 'WLAN')

$interfacesEn = "There is 1 interface on the system:`n`n    Name                   : WLAN`n    Description            : MediaTek Wi-Fi 6E MT7922`n    GUID                   : 11111111-1111-1111-1111-111111111111`n    Physical address       : aa:bb:cc:dd:ee:ff`n    State                  : connected`n    SSID                   : 701`n    BSSID                  : 11:22:33:44:55:66`n    Profile                : 701`n    Signal                 : 82%`n"
$interfacesZh = "系统上有 1 个接口:`n`n    名称                   : WLAN`n    状态                   : 已连接`n    SSID                   : 702`n    BSSID                  : 11:22:33:44:55:66`n    配置文件               : 702`n"
$blocksEn = @(ConvertFrom-SafeRecoveryWlanInterface -Output $interfacesEn)
$blocksZh = @(ConvertFrom-SafeRecoveryWlanInterface -Output $interfacesZh)
Assert-True '英文接口块解析出 Name 与 Profile' ($blocksEn.Count -eq 1 -and $blocksEn[0].Name -eq 'WLAN' -and $blocksEn[0].Profile -eq '701')
Assert-True '中文接口块解析出 Name 与 Profile' ($blocksZh.Count -eq 1 -and $blocksZh[0].Profile -eq '702')
Assert-True 'BSSID 绝不会被当成配置文件采集' ($blocksEn[0].Profile -ne '11:22:33:44:55:66')

Write-Host "`n[5] IPv4 可用性与脱敏" -ForegroundColor Cyan
Assert-True '192.168.0.103 可用' (Test-SafeRecoveryIPv4Usable -IPAddress '192.168.0.103')
Assert-True 'APIPA 169.254.x.x 不可用' (-not (Test-SafeRecoveryIPv4Usable -IPAddress '169.254.12.9'))
Assert-True '0.0.0.0 不可用' (-not (Test-SafeRecoveryIPv4Usable -IPAddress '0.0.0.0'))
Assert-True '127.0.0.1 不可用' (-not (Test-SafeRecoveryIPv4Usable -IPAddress '127.0.0.1'))
Assert-True '空值不可用' (-not (Test-SafeRecoveryIPv4Usable -IPAddress ''))
Assert-True '非法字符串不可用' (-not (Test-SafeRecoveryIPv4Usable -IPAddress 'not-an-ip'))
Assert-True 'IPv6 不算 IPv4 可用' (-not (Test-SafeRecoveryIPv4Usable -IPAddress 'fe80::1'))
Assert-True '白名单配置文件原样保留' ((Format-SafeRecoveryProfileName -Name '701' -AllowedProfile @('701', '702')) -eq '701')
Assert-True '无关 SSID 被脱敏' ((Format-SafeRecoveryProfileName -Name 'MyHomeWiFi' -AllowedProfile @('701', '702')) -eq 'My***i')
Assert-True '空值显示 (none)' ((Format-SafeRecoveryProfileName -Name '' -AllowedProfile @('701')) -eq '(none)')

Write-Host "`n[6] 关联判定：WLAN 与 NLA 双来源" -ForegroundColor Cyan
$nlaLate = New-FakeState -ConnectedProfile $null
$nlaSuffixed = New-FakeState -ConnectedProfile '701 2'
$wlanMissing = New-FakeState -WlanProfile $null
Assert-True 'NLA 滞后时 WLAN 仍可确认关联' (Test-SafeRecoveryProfileMatch -State $nlaLate -ExpectedProfile '701')
Assert-True 'NLA 出现去重后缀时不影响判定' (Test-SafeRecoveryProfileMatch -State $nlaSuffixed -ExpectedProfile '701')
Assert-True 'WLAN 读取失败时 NLA 可兜底' (Test-SafeRecoveryProfileMatch -State $wlanMissing -ExpectedProfile '701')
Assert-True '两个来源都不匹配则判为未关联' (-not (Test-SafeRecoveryProfileMatch -State (New-FakeState -WlanProfile '702' -ConnectedProfile '702') -ExpectedProfile '701'))
Assert-True '识别出当前活动的白名单配置文件' ((Get-SafeRecoveryActiveAllowedProfile -State (New-FakeState -WlanProfile '702' -ConnectedProfile '702') -AllowedProfile @('701', '702')) -eq '702')
Assert-True '非白名单网络不返回活动配置文件' ($null -eq (Get-SafeRecoveryActiveAllowedProfile -State (New-FakeState -WlanProfile 'Other' -ConnectedProfile 'Other') -AllowedProfile @('701', '702')))

Write-Host "`n[7] 成功后置条件判定" -ForegroundColor Cyan
Assert-True '健康状态判定成功' ((Test-SafeRecoveryConnectionHealthy -State (New-FakeState) -ExpectedProfile '701').IsHealthy)
Assert-True 'APIPA 判定失败' (-not (Test-SafeRecoveryConnectionHealthy -State (New-FakeState -IPv4Address '169.254.5.5' -HasDefaultRoute $false) -ExpectedProfile '701').IsHealthy)
Assert-True '缺少默认路由判定失败' (-not (Test-SafeRecoveryConnectionHealthy -State (New-FakeState -HasDefaultRoute $false) -ExpectedProfile '701').IsHealthy)
Assert-True '介质未连接判定失败' (-not (Test-SafeRecoveryConnectionHealthy -State (New-FakeState -MediaConnectionState 'Disconnected') -ExpectedProfile '701').IsHealthy)
Assert-True '连错配置文件判定失败' (-not (Test-SafeRecoveryConnectionHealthy -State (New-FakeState) -ExpectedProfile '702').IsHealthy)
Assert-True '失败原因被记录' ((Test-SafeRecoveryConnectionHealthy -State (New-FakeState -IPv4Address '169.254.5.5' -HasDefaultRoute $false) -ExpectedProfile '701').Reasons.Count -ge 2)
Assert-True '等待条件 Associated 正确' (Test-SafeRecoveryWaitCondition -State (New-FakeState) -Condition 'Associated' -ExpectedProfile '701')
Assert-True '等待条件 UsableAddress 对 APIPA 为假' (-not (Test-SafeRecoveryWaitCondition -State (New-FakeState -IPv4Address '169.254.5.5') -Condition 'UsableAddress'))

Write-Host "`n[8] 只读 netsh 守卫" -ForegroundColor Cyan
Assert-Throws '缺少 show 动词被拒绝' { Invoke-SafeRecoveryReadOnlyNetsh -ArgumentList @('wlan', 'profiles') }
Assert-Throws '包含 connect 被拒绝' { Invoke-SafeRecoveryReadOnlyNetsh -ArgumentList @('wlan', 'show', 'connect') }
Assert-Throws '包含 delete 被拒绝' { Invoke-SafeRecoveryReadOnlyNetsh -ArgumentList @('wlan', 'show', 'delete') }
Assert-Throws '包含 set 被拒绝' { Invoke-SafeRecoveryReadOnlyNetsh -ArgumentList @('wlan', 'show', 'set') }
Assert-Throws 'key=clear 被拒绝' { Invoke-SafeRecoveryReadOnlyNetsh -ArgumentList @('wlan', 'show', 'profile', 'name=701', 'key=clear') }

Write-Host "`n[9] 写操作守卫 (在调用系统命令之前拦截)" -ForegroundColor Cyan
Assert-Throws '白名单外配置文件被拒绝连接' { Invoke-SafeRecoveryWlanConnect -ProfileName '999' -AllowedProfile @('701', '702') -InterfaceName 'WLAN' }
Assert-Throws '绕过配置白名单也会被硬编码白名单拦截' { Invoke-SafeRecoveryWlanConnect -ProfileName 'Guest' -AllowedProfile @('701', '702', 'Guest') -InterfaceName 'WLAN' }
Assert-Throws '注入式配置文件名被拒绝' { Invoke-SafeRecoveryWlanConnect -ProfileName '701 & calc' -AllowedProfile @('701', '701 & calc') -InterfaceName 'WLAN' }
Assert-Throws '空接口名被拒绝' { Invoke-SafeRecoveryWlanConnect -ProfileName '701' -AllowedProfile @('701') -InterfaceName '  ' }
$dryRun = Invoke-SafeRecoveryWlanConnect -ProfileName '701' -AllowedProfile @('701', '702') -InterfaceName 'WLAN' -WhatIf
Assert-True '-WhatIf 下不执行 netsh' ($dryRun.Executed -eq $false -and $null -eq $dryRun.ExitCode)
Assert-True '-WhatIf 下命令向量仍限定为 connect + 白名单' ($dryRun.Command -eq 'netsh wlan connect name=701 interface=WLAN')

Write-Host "`n[10] 永久红线静态自检 (可执行代码不得出现禁止操作)" -ForegroundColor Cyan
$forbiddenPatterns = @(
    @{ Name = 'ipconfig /release'; Pattern = '/release' },
    @{ Name = 'DNS 刷新'; Pattern = 'flushdns|Clear-DnsClientCache' },
    @{ Name = 'registerdns'; Pattern = 'registerdns' },
    @{ Name = 'Winsock 重置'; Pattern = 'winsock\s+reset' },
    @{ Name = 'TCP/IP 重置'; Pattern = 'int\s+ip\s+reset|netcfg\s+-d' },
    @{ Name = '网卡启停'; Pattern = '(Disable|Enable|Restart)-NetAdapter' },
    @{ Name = '注册表写入'; Pattern = '(Set|New|Remove)-ItemProperty' },
    @{ Name = '代理修改'; Pattern = 'winhttp\s+(set|reset)' },
    @{ Name = 'Wi-Fi 配置文件增删改'; Pattern = "wlan[\s'`",]+(delete|add|set|export|disconnect)" },
    @{ Name = '明文密钥'; Pattern = 'key\s*=\s*clear' },
    @{ Name = '服务变更'; Pattern = '(Start|Stop|Restart)-Service|New-Service' },
    @{ Name = '计划任务变更'; Pattern = 'schtasks|Register-ScheduledTask|Unregister-ScheduledTask' },
    @{ Name = '结束进程'; Pattern = 'Stop-Process' },
    @{ Name = '接口与路由改写'; Pattern = 'Set-NetIPInterface|Set-NetIPAddress|New-NetRoute|Remove-NetRoute|Set-NetAdapter' },
    @{ Name = '动态执行'; Pattern = 'Invoke-Expression' }
)
$scannedFiles = @(
    (Join-Path $ModulesDir 'SafeRecoveryObservation.psm1'),
    (Join-Path $ModulesDir 'SafeRecoveryActions.psm1'),
    (Join-Path $AppDir 'NetworkSafeRecovery.ps1'),
    (Join-Path $ToolRoot 'START-SAFE-RECOVERY.cmd')
)
$violations = New-Object System.Collections.Generic.List[string]
foreach ($file in $scannedFiles) {
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $file)) {
        $lineNumber++
        $trimmed = $line.Trim()
        # 注释中的「禁止清单」是文档，不是可执行代码
        if ($trimmed.StartsWith('#') -or $trimmed.StartsWith('::') -or $trimmed -match '^(?i)rem\s') { continue }
        foreach ($rule in $forbiddenPatterns) {
            if ($line -match $rule.Pattern) {
                $violations.Add("$(Split-Path -Leaf $file):$lineNumber $($rule.Name)")
            }
        }
    }
}
Assert-True '可执行代码中没有任何禁止操作' ($violations.Count -eq 0)
foreach ($violation in $violations) { Write-Host "        违规: $violation" -ForegroundColor Red }

$actionsText = Get-Content -LiteralPath (Join-Path $ModulesDir 'SafeRecoveryActions.psm1') -Raw
$connectSites = ([regex]"@\('wlan', 'connect'").Matches($actionsText).Count
$renewSites = ([regex]"@\('/renew'").Matches($actionsText).Count
Assert-True '受限写操作层内 connect 调用点恰好 1 处' ($connectSites -eq 1)
Assert-True '受限写操作层内 renew 调用点恰好 1 处' ($renewSites -eq 1)

$observationText = Get-Content -LiteralPath (Join-Path $ModulesDir 'SafeRecoveryObservation.psm1') -Raw
Assert-True '只读观察层内没有任何写操作调用点' (-not ($observationText -match "@\('wlan', 'connect'|@\('/renew'"))

Write-Host "`n=======================================================================" -ForegroundColor Cyan
Write-Host " 测试结果: PASS=$script:Passed  FAIL=$script:Failed" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
Write-Host "=======================================================================" -ForegroundColor Cyan

if ($script:Failed -gt 0) { exit 1 }
exit 0

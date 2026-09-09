# ==============================================================================
# NetworkRecovery.Config.psd1
# 便携网络只读诊断工具箱配置文件
# 所有路径均基于相对路径 ($ToolRoot)
# ==============================================================================
@{
    # 公网直连 TCP 握手探测目标 (绕过代理直连测试)
    PublicWanTargets = @(
        "223.5.5.5:53",
        "119.29.29.29:53",
        "114.114.114.114:53",
        "www.baidu.com:443"
    )

    # TCP 直连握手超时时间 (毫秒)
    TcpProbeTimeoutMs = 5000

    # DNS 域名解析测试域名
    DnsTestDomain = "www.microsoft.com"

    # 核心网络服务检测列表 (包含网络基础、无线与代理探测服务)
    CoreNetworkServices = @("Dhcp", "Dnscache", "nsi", "Wlansvc", "NlaSvc", "WinHttpAutoProxySvc")

    # 驱动导出最低 U 盘可用空间 (MB)
    MinFreeSpaceMBForDrivers = 500

    # --------------------------------------------------------------------------
    # 断网时间线关联分析配置
    # --------------------------------------------------------------------------

    # 默认回溯时长 (小时)
    TimelineDefaultHoursBack = 24

    # 本机看门狗日志路径 (可选，不存在时自动跳过)
    WatchdogLogPath = "D:\agentNeural Network Knowledge Base\network\network_recovery.log"

    # 时间线分析纳入的 System 日志网络 Provider 列表
    TimelineSystemProviders = @(
        "mtkwlex",
        "Microsoft-Windows-WLAN-AutoConfig",
        "Microsoft-Windows-DNS-Client",
        "Tcpip",
        "Microsoft-Windows-Dhcp-Client",
        "Microsoft-Windows-DHCPv6-Client",
        "Service Control Manager"
    )

    # 关键网络事件 ID 分类映射 (严格区分故障与正常拆除)
    TimelineEventClassifications = @{
        # WLAN 断开事件 ID (仅限真实物理/驱动断开，口径已严格校准)
        DisconnectEventIds = @(8003)

        # WLAN 正常安全会话拆除事件 ID (属于正常会话结束流程，非故障事件)
        SecurityStoppedEventIds = @(11004)

        # WLAN 连接/重连失败事件 ID
        ConnectionFailureEventIds = @(8002)

        # 动态密钥交换超时事件 ID
        KeyExchangeTimeoutEventIds = @(11006)

        # 关联与安全协商事件 ID (正常流程类)
        AssociationEventIds = @(8000, 8001, 11000, 11001, 11005, 11010)

        # DNS 解析超时/失败事件 ID
        DnsErrorEventIds = @(1014)

        # TCP/IP 协议栈异常事件 ID
        TcpipErrorEventIds = @(4207)

        # 异常 RSSI 判定数值 (例如 255 表示网络不可用/探测异常)
        AbnormalRssiValues = @(255)
    }

    # --------------------------------------------------------------------------
    # WLAN 原因码分组归类映射配置
    # 码 -> 归类名。含义文本一律通过 WlanReasonCodeToString API 动态解析，严禁写死文本
    # 分组依据严格基于官方 API 返回文本与事件上下文
    # --------------------------------------------------------------------------
    WlanReasonCodeGroups = @{
        0      = "成功"
        163851 = "网络不可用"
        294917 = "安全握手超时"
    }

    # --------------------------------------------------------------------------
    # 健康基线保存与差异比对配置 (新增)
    # --------------------------------------------------------------------------

    # 稳定字段列表 (默认参与异常比对，任何变化均视为潜在网络异常)
    BaselineStableFields = @(
        "InterfaceGuid",
        "MacAddress",
        "InterfaceDescription",
        "HardwareInterface",
        "DhcpEnabled",
        "DnsServers",
        "DefaultGateway",
        "ProxyEnable",
        "ProxyServer",
        "ProxyOverride",
        "AutoConfigURL",
        "ServiceStartTypes",
        "IPv6HasDefaultRoute"
    )

    # 易变字段列表 (默认不参与异常判定，单独列出作为环境参考信息)
    BaselineVolatileFields = @(
        "IPv4Address",
        "DhcpRemainingMinutes",
        "LinkSpeed",
        "ReceiveRate",
        "TransmitRate",
        "SignalPercent",
        "RssiEstimated",
        "RouteMetric",
        "EffectiveMetric",
        "ServiceStatuses"
    )

    # --------------------------------------------------------------------------
    # 网卡高级属性分类与现代待机配置 (语义化分类，避免枚举误报)
    # --------------------------------------------------------------------------

    # 需关注类关键字清单 (布尔开关：开启可能影响连接稳定性/微睡眠掉线的激进省电项)
    PowerSaveAttentionKeywords = @(
        "U-APSD", "UAPSD", "APSD",
        "MIMO Power Save", "MIMO 省电",
        "Power Save", "Power Saving", "省电", "节能", "LowPowerEnable",
        "Selective Suspend", "选择性挂起"
    )

    # 正常类关键字清单 (布尔开关：现代待机机型上开启属预期行为/睡眠唤醒与网络卸载项)
    PowerSaveNormalKeywords = @(
        "ARP Offload", "NS Offload", "DisableARPOffload",
        "GTK Rekey", "DisableGTKRekey",
        "唤醒幻数据包", "DisableWakeOnMagic",
        "唤醒模式匹配", "DisableWakeOnPattern",
        "Sleep on WoWLAN", "WoWLAN", "Packet Coalescing", "数据包合并"
    )

    # 枚举选择型关键字清单 (非布尔开关：多值枚举配置，不判启用禁用，只作选项标记)
    PowerSaveEnumKeywords = @(
        "Roaming Aggressiveness", "Roaming Sensitivity", "漫游", "RoamIndicateTh",
        "Preferred Band", "Band Preference", "频段", "频带", "PreferredBand",
        "Throughput Booster", "Throughput Enhancement", "吞吐",
        "Transmit Power", "传输功率", "发射功率", "TxPowerLevel"
    )

    # 是否在控制台显示未命中关键字的全部高级属性 (默认 False，全量属性始终完整写入 logs\)
    ShowAllAdvancedProperties = $false

    # --------------------------------------------------------------------------
    # 现代待机会话与电源事件关联分析配置 (仅基于本机真实枚举出的 Kernel-Power 事件 ID)
    # --------------------------------------------------------------------------

    # Kernel-Power 事件分类映射表 (严禁配置枚举中不存在的 ID)
    KernelPowerEventClassifications = @{
        # 进入低功耗/待机/关机转换事件 ID (Event 109)
        EnterLowPowerEventIds = @(109)

        # 退出低功耗/唤醒/重启恢复事件 ID (Event 41, 577)
        ExitLowPowerEventIds  = @(41, 577)

        # 现代待机连通性状态变更事件 ID (Event 172: Disconnected 离线 / Connected 连通)
        StandbyConnectivityEventIds = @(172)

        # 供电与硬件辅助状态事件 ID (Event 125 温区枚举 / Event 521 电池状态)
        PowerAuxiliaryEventIds = @(125, 521)
    }

    # 现代待机退出唤醒容限时间 (秒，退出低功耗后在此时间窗口内的断网判定为唤醒关联断网)
    StandbyWakeGracePeriodSeconds = 30

    # 现代待机会话临近容限时间 (秒)
    StandbySessionProximitySeconds = 60
}

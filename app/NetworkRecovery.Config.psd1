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

    # 关键网络事件 ID 分类映射
    TimelineEventClassifications = @{
        # WLAN 断开事件 ID
        DisconnectEventIds = @(8003, 11004)

        # WLAN 连接/重连失败事件 ID
        ConnectionFailureEventIds = @(8002)

        # 动态密钥交换超时事件 ID
        KeyExchangeTimeoutEventIds = @(11006)

        # 关联与安全协商事件 ID
        AssociationEventIds = @(8000, 8001, 11000, 11001, 11005, 11010)

        # DNS 解析超时/失败事件 ID
        DnsErrorEventIds = @(1014)

        # TCP/IP 协议栈异常事件 ID
        TcpipErrorEventIds = @(4207)

        # 异常 RSSI 判定数值 (例如 255 表示网络不可用/探测异常)
        AbnormalRssiValues = @(255)
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
}

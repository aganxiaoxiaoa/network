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
    # 断网时间线关联分析配置 (新增)
    # --------------------------------------------------------------------------

    # 默认回溯时长 (小时)
    TimelineDefaultHoursBack = 24

    # 本机看门狗日志路径 (可选，不存在时自动跳过)
    WatchdogLogPath = "D:\agentNeural Network Knowledge Base\network\network_recovery.log"

    # 时间线分析纳入的 System 日志网络 Provider 列表
    # 基于实机枚举结果：
    # - mtkwlex: 物理无线网卡 (MediaTek MT7922) 底层驱动
    # - Microsoft-Windows-WLAN-AutoConfig: 系统 WLAN 核心自动配置服务
    # - Microsoft-Windows-DNS-Client: 域名解析服务与超时事件 (ID 1014)
    # - Tcpip: TCP/IP 协议栈接口绑定与错误 (ID 4207)
    # - Microsoft-Windows-Dhcp-Client: IPv4 DHCP 租约服务
    # - Microsoft-Windows-DHCPv6-Client: IPv6 DHCP 租约服务
    # - Service Control Manager: 服务启停与状态流转 (ID 7036/7040/7045)
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
}

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
}

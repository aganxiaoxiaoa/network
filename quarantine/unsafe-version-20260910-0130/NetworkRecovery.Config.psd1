# ==============================================================================
# NetworkRecovery.Config.psd1
# 便携网络恢复与诊断工具箱全局配置文件
# 所有路径均基于工具根目录 ($PSScriptRoot) 的相对路径
# ==============================================================================
@{
    # 公网直连 TCP 探测目标 (格式: "Host:Port")
    # 采用不同运营商、不同协议端口 (53/443)，跨协议跨链路探测，避免公共 DNS 偶发限流误判
    PublicWanTargets = @(
        "223.5.5.5:53",
        "119.29.29.29:53",
        "114.114.114.114:53",
        "www.baidu.com:443"
    )

    # 原始 TCP 直连握手超时时间 (毫秒)
    TcpProbeTimeoutMs = 5000

    # 域名解析健康检查目标
    DnsTestDomain = "www.microsoft.com"

    # 工具箱相对路径配置 (严禁硬编码绝对盘符)
    OutputDirectory    = "output"
    LogsDirectory      = "logs"
    DriversDirectory   = "output\drivers"
    SnapshotsDirectory = "output\snapshots"

    # 导出驱动所需最低 U 盘剩余空间 (MB)
    MinFreeSpaceMBForDrivers = 500

    # 核心监控与依赖 Windows 服务
    CoreNetworkServices = @("Dhcp", "Dnscache", "nsi", "Wlansvc")

    # 快照索引指针文件相对路径
    ProxySnapshotPointerRelativePath = "output\latest-proxy-snapshot.json"
}
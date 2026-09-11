# ==============================================================================
# SafeRecovery.Config.psd1
# 独立安全恢复模块专用配置 (与只读诊断配置 NetworkRecovery.Config.psd1 完全分离)
# 本文件是纯数据文件，仅允许包含：Wi-Fi 配置文件白名单、超时与轮询参数、日志目录
# ==============================================================================
@{
    # 唯一允许连接的 Wi-Fi 配置文件名称白名单 (精确匹配，不做任何模糊匹配或通配)
    AllowedProfiles          = @('701', '702')

    # 默认优先尝试的配置文件
    PrimaryProfile           = '701'

    # 主配置文件失败后自动回退的配置文件
    FallbackProfile          = '702'

    # netsh wlan connect 之后等待关联与安全握手完成的最长秒数
    ConnectTimeoutSeconds    = 20

    # 关联成功后先等待 DHCP 自动完成的秒数 (仍未取得可用地址才执行一次续租)
    DhcpAutoWaitSeconds      = 8

    # DHCP 续租之后等待取得可用 IPv4 地址的最长秒数
    DhcpWaitSeconds          = 30

    # 状态轮询间隔毫秒
    PollIntervalMilliseconds = 1000

    # 网关 ICMP 探测次数 (仅写入日志作为参考，绝不作为成功判定条件)
    GatewayPingCount         = 2

    # 恢复日志目录 (U 盘内相对路径，绝不写入系统盘)
    LogSubDirectory          = 'logs\safe-recovery'

    # 必须由用户逐字输入的确认令牌
    ConfirmationToken        = 'YES'
}

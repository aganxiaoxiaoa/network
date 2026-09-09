@{
    ProbeTargets = @{
        PingGateway = $true
        TcpTargets = @(
            @{ Host = "223.5.5.5"; Port = 53; Description = "AliDNS Public DNS (TCP 53)" },
            @{ Host = "119.29.29.29"; Port = 53; Description = "DNSPod Public DNS (TCP 53)" },
            @{ Host = "180.101.50.188"; Port = 443; Description = "Baidu Public HTTPS (TCP 443)" },
            @{ Host = "203.107.1.1"; Port = 80; Description = "AliCloud NTP/HTTP (TCP 80)" }
        )
        DnsDomains = @(
            "www.baidu.com",
            "www.aliyun.com",
            "www.msftconnecttest.com"
        )
    }

    CoreServices = @(
        "Dhcp",
        "Dnscache",
        "nsi",
        "Wlansvc",
        "NlaSvc",
        "WinHttpAutoProxySvc"
    )

    Storage = @{
        OutputDir    = "output"
        LogsDir      = "logs"
        SnapshotsDir = "output\snapshots"
        DriversDir   = "output\drivers"
    }

    SafetyRules = @{
        MaxDnsTimeoutMs      = 3000
        MaxTcpTimeoutMs      = 3000
        RequireConfirmation  = $true
        MinFreeDiskSpaceMB   = 500
    }
}

# README-FIRST: 便携网络诊断工具箱安全使用须知 (只读安全版)

================================================================================
【重要安全声明】当前版本为纯只读网络诊断工具，绝不修改系统网络！
================================================================================

由于此前在网络恢复测试中曾发生过物理 Wi-Fi 偶发断网事故，按照最高安全准则：
**本工具箱已全面降级并锁定为“纯只读诊断工具”，彻底剔除所有状态修改命令。**

---

### 一、当前工具的 5 大安全保证

1. **绝对只读**：本工具绝不执行任何网络重置、网卡重启、DNS 刷新、DHCP 续租、Winsock 重置或代理注册表修改操作！
2. **零系统残留**：拔出 U 盘后，宿主机不会留下任何计划任务、Windows 服务、开机启动项或常驻后台进程。
3. **完全驻留 U 盘**：所有诊断日志、报告包和备份均保存在 U 盘自身目录内，绝不污染系统盘。
4. **单实例保护**：工具启动时具备单实例互斥锁，严防重复运行。
5. **本地看门狗互斥**：工具启动时自动探测本地是否有正在运行的看门狗服务；若检测到，会自动锁定为纯只读观察模式，绝对不停止、不修改、不干扰本地看门狗。

---

### 二、目录结构

```text
Network-Recovery-USB\
├── README-FIRST.md               # 本安全声明与使用指南 (必读)
├── START-DIAGNOSIS.cmd           # 双击启动入口 (纯 ASCII，普通权限，只读诊断)
├── app\
│   ├── NetworkDiagnostics.ps1    # 主控只读诊断程序
│   ├── NetworkRecovery.Config.psd1 # 配置文件 (相对路径，探测目标)
│   └── modules\
│       ├── NetworkInventory.psm1 # 网络清单与静态信息采集模块
│       ├── NetworkHealth.psm1    # 纯只读健康探测模块
│       └── DiagnosticArtifacts.psm1 # 诊断脱敏报告与驱动备份模块
├── docs\
│   ├── 使用说明.md               # 详细使用指南
│   ├── 安全边界.md               # 严密的安全红线与机制说明
│   ├── 事故调查报告.md           # 2026-09-10 断网事件客观调查与时间线分析
│   └── 官方资料.md               # 微软与 Intel 官方权威技术依据
├── manifests\
│   ├── file-inventory-before.csv # 整理前全量文件清单 (含 SHA-256)
│   ├── file-inventory-after.csv  # 整理后全量文件清单 (含 SHA-256)
│   └── SHA256SUMS.txt            # 核心工具文件 SHA-256 哈希完整性清单
├── backups\                      # 备份目录 (包含归档的参考看门狗文件与驱动备份)
│   └── Network-Reference-Watchdog/
├── quarantine\                   # 危险历史版本隔离区 (已加 .disabled 禁用)
│   └── unsafe-version-20260910-0130/
├── output\                       # 诊断报告压缩包生成目录
└── logs\                         # 运行日志目录
```

---

### 三、使用方法与交互菜单详解

1. **双击启动**：
   直接双击 `START-DIAGNOSIS.cmd` 即可启动终端只读菜单（默认以普通权限运行）。
2. **交互式主菜单选项与代码实际定义 (app/NetworkDiagnostics.ps1)**：
   - `[1] Execute Read-Only Network Diagnostics` (执行纯只读网络健康诊断)：
     调用 `Invoke-FullHealthDiagnosis`，分层执行 9 项纯只读探测（默认路由、网关响应、4公网TCP直连握手、DNS解析、WinINET/WinHTTP代理状态、核心网络服务），控制台实时滚动显示探测结果。
   - `[2] Generate Diagnostic Log Bundle (ZIP)` (生成诊断日志压缩包)：
     交互提示 `Include WLAN profiles? (Y/N, default N)`（默认 N，即不包含明文 SSID 与 Wi-Fi 配置文件），调用 `New-DiagnosticBundle -IncludeWlanProfiles:$include` 在 `output\` 生成脱敏 `NetworkDiagnosticBundle-*.zip`。
   - `[3] Export Third-Party Network Driver Catalog` (导出第三方网络驱动清单与包)：
     调用 `Export-DriverCatalog`。若当前为普通用户权限，检测到未提权后打印 `Driver catalog export requires Administrator privileges.` 及 `Relaunching with elevation...`，通过 UAC 弹窗提权启动新进程只读导出至 `backups\` 目录；若已具备管理员权限则直接运行 `pnputil /export-driver` 备份。
   - `[0] Exit` (退出)：
     打印 `Exiting.`，跳出主循环并释放单实例互斥锁退出。

---

### 四、严禁运行隔离区 (quarantine)

`quarantine\` 目录中封存了曾与断网事故同时发生的旧版本文件。
其入口文件已更名为 `.disabled`。**严禁恢复扩展名、严禁尝试运行隔离区中的任何文件！**


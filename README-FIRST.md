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
│       ├── DiagnosticArtifacts.psm1 # 诊断脱敏报告与驱动备份模块
│       └── NetworkBaseline.psm1  # 健康基线保存与差异比对模块 (纯只读)
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
├── output\                       # 诊断报告压缩包与健康基线目录 (含 baseline\)
└── logs\                         # 运行日志目录
```

---

### 三、使用方法与交互菜单详解

1. **双击启动**：
   直接双击 `START-DIAGNOSIS.cmd` 即可启动终端只读菜单（默认以普通权限运行）。
2. **交互式主菜单选项与代码实际定义 (app/NetworkDiagnostics.ps1)**：
   - `[1] Execute Read-Only Network Diagnostics (执行纯只读网络健康与配置诊断)`：
     调用 `Invoke-RunDiagnosis`，分层执行 12 项纯只读探测（看门狗互斥、IPv4路由网关、IPv6双栈与黑洞检测、网卡电源管理、无线链路质量与协商速率、IP与DHCP租约周期、NCSI连通性判定与探针、网关ICMP响应、4公网TCP直连握手、DNS解析、WinINET/WinHTTP代理状态、6大核心网络服务与职责），控制台实时滚动显示探测结果。
   - `[2] Generate Diagnostic Log Bundle (ZIP) (生成诊断报告与脱敏压缩包)`：
     交互提示 `Include WLAN profiles? (Y/N, default N)`（默认 N，即不包含明文 SSID 与 Wi-Fi 配置文件），调用 `New-DiagnosticBundle -ToolRoot $ToolRoot -IncludeWlanReport:$incWlan` 在 `output\` 生成脱敏 `NetworkDiagnosticBundle-*.zip`。
   - `[3] Export Third-Party Network Driver Catalog (导出第三方网络驱动清单与包)`：
     调用 `Export-NetworkDrivers`。若当前为普通用户权限，检测到未提权后打印 `Driver catalog export requires Administrator privileges.` 及 `Relaunching with elevation...`，通过 UAC 弹窗提权启动新进程只读导出至 `backups\network-drivers-*` 目录；若已具备管理员权限则直接运行 `pnputil /export-driver` 备份。
   - `[4] Analyze Disconnection Timeline (断网时间线关联分析)`：
     调用 `Invoke-RunTimelineAnalysis`，三路只读合并分析 WLAN Operational 日志、System 日志关键网络事件与本机看门狗日志（可选）。统计断开事件次数、连接失败次数、密钥交换超时、异常 RSSI 值（如 255）及看门狗动作执行历史。控制台展示汇总统计与最近 20 条事件流，完整时序表自动落盘写入 `logs\timeline_*.log`。末尾附带官方免责说明：“以上仅为时间相关性，不构成因果结论。”
   - `[5] Save Health Baseline (保存当前健康基线)`：
     调用 `Save-NetworkBaseline`，采集当前网络配置与健康状态结构化快照并保存至 `output\baseline\baseline-yyyyMMdd-HHmmss.json`，同时更新纯相对文件名指针 `output\baseline\latest.txt`（严格无盘符）。退出码：0 成功，1 错误。
   - `[6] Compare With Baseline (与基线比对差异)`：
     调用 `Compare-NetworkBaseline`，支持交互输入指定基线文件或直接回车比对由 `latest.txt` 指向的最近基线。精准比对 13 项核心稳定字段与 10 项易变参考指标，明细自动落盘写入 `logs\baseline_compare_*.log`。退出码：0 稳定字段无差异，2 发现核心稳定字段差异 (潜在网络异常)，1 执行错误。
   - `[0] Exit (退出工具箱)`：
     打印 `Exiting.`，跳出主循环并释放单实例互斥锁退出。

3. **命令行执行 (-Action 逐字对应)**：
   - `-Action FullHealth` / `-Action Diagnose`：执行 12 项纯只读网络健康诊断
   - `-Action Timeline [-HoursBack N]`：执行断网时间线关联分析 (默认回溯 24 小时)
   - `-Action Bundle`：生成脱敏诊断报告并打包至 `output\`
   - `-Action BackupDrivers` / `-Action ExportDrivers`：导出第三方网络驱动至 `backups\`
   - `-Action SaveBaseline`：保存当前网络健康与配置基线 (退出码: 0成功, 1错误)
   - `-Action CompareBaseline [-BaselineFile <文件名或路径>]`：与基线比对差异 (退出码: 0无差异, 2有差异, 1错误)
   - `-Action Menu`：打开交互式主菜单 (默认)
   - `-Action Help`：查看帮助信息

---

### 四、严禁运行隔离区 (quarantine)

`quarantine\` 目录中封存了曾与断网事故同时发生的旧版本文件。
其入口文件已更名为 `.disabled`。**严禁恢复扩展名、严禁尝试运行隔离区中的任何文件！**

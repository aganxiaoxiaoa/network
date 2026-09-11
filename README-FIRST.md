# README-FIRST: 便携网络诊断工具箱安全使用须知 (只读诊断 + 受限安全恢复)

================================================================================
【重要安全声明】本工具箱有两个彼此完全隔离的入口，请按需选择：

| 双击入口 | 用途 | 是否修改网络 |
| :--- | :--- | :--- |
| `START-DIAGNOSIS.cmd` | 只读诊断、取证、采样、基线 | **绝对只读，永不修改任何网络状态** |
| `START-SAFE-RECOVERY.cmd` | 恢复上网 (仅 701/702 + 无线 DHCP 续租) | **仅两项授权写操作，需逐字输入 YES 确认** |
================================================================================

由于此前在网络恢复测试中曾发生过物理 Wi-Fi 偶发断网事故，按照最高安全准则：
**诊断入口 `START-DIAGNOSIS.cmd` 及其 4 个诊断模块永久锁定为“纯只读”，彻底剔除所有状态修改命令。**

2026-09 经用户明确授权，新增了一个**物理与逻辑上完全独立**的受限恢复入口
`START-SAFE-RECOVERY.cmd`。它不共用诊断主控与诊断模块，且被授权的写操作只有两项：
1. `netsh wlan connect` 连接**白名单内**的 Wi-Fi 配置文件 (`701` / `702`)；
2. `ipconfig /renew "<已验证的物理无线网卡>"`。

除此之外的一切写操作（代理、Winsock、TCP/IP Reset、注册表、DNS 刷新、
`ipconfig /release`、Wi-Fi 配置文件增删改、网卡启停、服务与计划任务、看门狗、路由器）
**永久禁止**，且失败后**绝不升级**到任何其他修复手段。

---

### 一、只读诊断入口 (`START-DIAGNOSIS.cmd`) 的 5 大安全保证

1. **绝对只读**：诊断入口绝不执行任何网络重置、网卡重启、DNS 刷新、DHCP 续租、Winsock 重置或代理注册表修改操作！
2. **零系统残留**：拔出 U 盘后，宿主机不会留下任何计划任务、Windows 服务、开机启动项或常驻后台进程。
3. **完全驻留 U 盘**：所有诊断日志、报告包和备份均保存在 U 盘自身目录内，绝不污染系统盘。
4. **单实例保护**：工具启动时具备单实例互斥锁，严防重复运行。
5. **本地看门狗互斥**：工具启动时自动探测本地是否有正在运行的看门狗服务；若检测到，会自动锁定为纯只读观察模式，绝对不停止、不修改、不干扰本地看门狗。

---

### 二、目录结构

```text
Network-Recovery-USB\
├── README-FIRST.md               # 本安全声明与使用指南 (必读)
├── START-DIAGNOSIS.cmd           # 双击入口 1: 纯只读诊断 (纯 ASCII，普通权限)
├── START-SAFE-RECOVERY.cmd       # 双击入口 2: 受限安全恢复 (纯 ASCII，会请求 UAC 提权)
├── app\
│   ├── NetworkDiagnostics.ps1    # 主控只读诊断程序 (与恢复完全隔离)
│   ├── NetworkRecovery.Config.psd1 # 只读诊断配置 (相对路径，探测目标)
│   ├── NetworkSafeRecovery.ps1   # 独立受限恢复主控 (不复用任何诊断模块)
│   ├── SafeRecovery.Config.psd1  # 恢复专用配置 (701/702 白名单与超时)
│   └── modules\
│       ├── NetworkInventory.psm1 # 网络清单与静态信息采集模块
│       ├── NetworkHealth.psm1    # 纯只读健康探测模块
│       ├── DiagnosticArtifacts.psm1 # 诊断脱敏报告与驱动备份模块
│       ├── NetworkBaseline.psm1  # 健康基线保存与差异比对模块 (纯只读)
│       ├── SafeRecoveryObservation.psm1 # 恢复用只读观察层 (识别网卡/读状态/判定健康)
│       └── SafeRecoveryActions.psm1     # 全工具箱唯一被授权执行写操作的文件 (仅 2 项)
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
    └── safe-recovery\            # 每次恢复的操作前后状态与退出码日志 (不含密钥/BSSID/公网 IP)
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
   - `[7] Start Read-Only Link Sampler (纯只读链路采样，不会修改任何设置)`：
     调用 `Start-LinkSampler`，对物理网络适配器状态、收发包及丢包错误计数、流量吞吐增量、网关 ARP 状态与 ICMP 响应、网络配置连通性等 19 项核心指标及单轮耗时（`CycleMs`）进行高频只读连续采样。支持动态 `-ToolRoot` 自动适配 U 盘盘符。新增 `-PingCount` 参数（默认 1，可选 0~3，0 为跳过 ping 并写 SKIPPED 以最大化采样频率）。默认采样间隔为 2 秒，持续 60 分钟（支持自定义间隔、Ping 次数与时长，或时长为 0 持续运行至按 Ctrl+C 停止）。若要精确捕获毫秒级断开事件（如 11004 → 8003 窗口），推荐使用 `-IntervalSeconds 1 -PingCount 1`（实测节奏 1.23 秒，单轮耗时约 215ms；PingCount=0 时实测节奏 1.21 秒，完全低于 1.5 秒）。采样记录实时按行追加至 `output\watch\link-sample-<yyyyMMdd-HHmmss>.csv`，它只读不写网络配置。注意：本采样器应在 Windows PowerShell 5.1 原生环境下运行。
   - `[0] Exit (退出工具箱)`：
     打印 `Exiting.`，跳出主循环并释放单实例互斥锁退出。

3. **命令行执行 (-Action 逐字对应)**：
   - `-Action FullHealth` / `-Action Diagnose`：执行 12 项纯只读网络健康诊断
   - `-Action Timeline [-HoursBack N]`：执行断网时间线关联分析 (默认回溯 24 小时)
   - `-Action Bundle`：生成脱敏诊断报告并打包至 `output\`
   - `-Action BackupDrivers` / `-Action ExportDrivers`：导出第三方网络驱动至 `backups\`
   - `-Action SaveBaseline`：保存当前网络健康与配置基线 (退出码: 0成功, 1错误)
   - `-Action CompareBaseline [-BaselineFile <文件名或路径>]`：与基线比对差异 (退出码: 0无差异, 2有差异, 1错误)
   - `-Action Watch [-IntervalSeconds N] [-DurationMinutes M] [-PingCount P] [-OutputPath <路径>]`：启动纯只读链路采样 (默认每 2 秒一次，PingCount=1，持续 60 分钟，输出至 `output\watch\`，末尾包含 CycleMs 轮次耗时，它只读不写网络配置。捕获断开事件推荐 `-IntervalSeconds 1 -PingCount 1` 实测节奏 1.23 秒，应在 Windows PowerShell 5.1 下运行)
   - `-Action Menu`：打开交互式主菜单 (默认)
   - `-Action Help`：查看帮助信息

---

### 四、受限安全恢复入口 (`START-SAFE-RECOVERY.cmd`)

**用途**：当电脑连着 `701` 却上不了网时，用它自动尝试恢复上网。

**双击后会发生什么**：
1. 请求 UAC 提权（`ipconfig /renew` 需要管理员权限）；若你拒绝提权，则安全退出，不做任何修改。
2. 与只读诊断共用同一把单实例锁，若诊断工具正在运行则直接中止。
3. 只读检测本地看门狗状态并给出警告（**绝不停止、绝不修改看门狗**）。
4. 识别**唯一**的物理无线网卡（802.11）；识别到 0 张或多张时立即中止，绝不猜测。
5. 打印恢复前状态与恢复计划，然后要求你**逐字输入 `YES`**；直接回车即取消，不修改网络。
6. 依次尝试 `701` → `702`（每个配置文件仅在本机**已保存**时才尝试）：
   - `netsh wlan connect name=<配置文件> interface=<无线网卡>`；
   - 轮询确认真正关联成功（退出码为 0 不代表已连上）；
   - 先等 DHCP 自动完成，仍拿不到地址时**只对该无线网卡**执行一次 `ipconfig /renew`；
   - 校验后置条件：配置文件正确、介质已连接、IPv4 非 `169.254.*`、该接口存在默认路由。
7. `701` 失败则自动回退 `702`；两者都失败即**停止**并写日志，不执行任何其他修复手段。

**命令行用法**（`-Action` 逐字对应）：
- `-Action Recover`（默认）：执行恢复，需逐字输入 `YES`
- `-Action Status`：**纯只读**预检，显示无线网卡、当前网络、白名单配置文件是否已保存与恢复计划
- `-Action Help`：显示帮助
- `-TargetProfile 701|702`：指定优先尝试的配置文件（默认 `701`，失败仍会回退另一个）
- `-InterfaceGuid <GUID>`：存在多张无线网卡时明确指定目标网卡（只能从已识别的无线网卡中选择）
- `-ConnectTimeoutSeconds <5-300>`：关联等待上限（默认 20 秒）
- `-DhcpWaitSeconds <5-300>`：DHCP 续租后等待上限（默认 30 秒）
- `-WhatIf`：只打印计划，不执行任何网络修改

**退出码**：`0` 成功 | `1` 环境或执行错误（含未提权、网卡歧义、白名单配置文件均未保存）| `2` 全部尝试后仍不可用 | `3` 用户取消。

**能力边界（必须知道）**：
若路由器/AP 侧根本不回应 DHCP（无 OFFER/ACK），本工具**无法**凭空造出租约。
此时它会如实报告失败并保留证据，请改用 `START-DIAGNOSIS.cmd` 采集现场后排查 AP 侧。

---

### 五、严禁运行隔离区 (quarantine)

`quarantine\` 目录中封存了曾与断网事故同时发生的旧版本文件。
其入口文件已更名为 `.disabled`。**严禁恢复扩展名、严禁尝试运行隔离区中的任何文件！**

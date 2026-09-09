# Windows 10/11 便携网络诊断与急救工具箱 (USB 独立版)

一套完全驻留于 U 盘、即插即用、零宿主污染的 Windows 10/11 专业网络急救工具。
专为解决各类网络异常、DNS 污染、代理残留劫持、网卡休眠假死及应急网络驱动备份而设计。

---

## 核心设计准则

1. **完全驻留于 U 盘**：工具本身、生成的诊断快照、日志、导出的硬件驱动及诊断压缩包全部保存在 U 盘根目录内。
2. **零系统残留**：拔除 U 盘后，宿主机不会残留任何计划任务、Windows 服务、开机启动项或后台常驻进程。
3. **相对路径独立性**：基于 PowerShell `$PSScriptRoot` 与 CMD `%~dp0`，不依赖固定盘符（如 `C:\`、`D:\` 或特定盘符），插入任意盘符均可双击直接启动。
4. **只读优先与最小权限**：默认入口与常规诊断完全为只读操作，不要求管理员权限；仅在用户主动选择涉及网卡重启、协议栈重置或驱动导出等高风险操作时，才按需触发 UAC 提权。
5. **严密的安全拦截与 WhatIf 机制**：
   - 绝不调用破坏性的 `netcfg -d`。
   - 绝不强制修改系统级 WinHTTP 代理。
   - 深度重置前自动扫描所有网络接口，若发现任何非 Loopback 静态 IP（包括断开的有线网卡），默认拒绝重置以保护固定配置。
   - 所有变更操作全面支持 `-WhatIf` 试运行，且 UAC 提权后依然完整保留 `-WhatIf` 状态。

---

## 目录结构

```text
Network-Recovery-USB/
├── Start-NetworkRecovery.cmd          # 双击启动入口 (纯 ASCII 批处理，普通权限启动)
├── NetworkRecovery.ps1                # 主控调度中心与交互控制台菜单 (UTF-8 BOM)
├── NetworkRecovery.Config.psd1        # 外部探测目标与超时配置 (UTF-8 BOM)
├── README.md                          # 本使用说明文档 (UTF-8 BOM)
├── SHA256SUMS.txt                     # 核心工具文件 SHA-256 完整性哈希清单
├── modules/
│   ├── NetworkDiagnostics.psm1        # 分层只读网络诊断模块 (UTF-8 BOM)
│   ├── RecoveryActions.psm1           # 安全修复、网卡重连、协议栈与代理恢复模块 (UTF-8 BOM)
│   └── RecoveryArtifacts.psm1         # 驱动备份与脱敏诊断包模块 (UTF-8 BOM)
├── output/
│   ├── drivers/                       # 导出的第三方网络硬件驱动与 CSV 清单
│   └── snapshots/                     # 网络状态快照与代理备份 JSON
└── logs/                              # 运行与会话日志目录
```

---

## 菜单功能一览

| 菜单编号 | 功能名称 | 权限要求 | 危险等级 | 说明 |
| :---: | :--- | :---: | :---: | :--- |
| **[1]** | **只读网络诊断** | 普通用户 | 零风险 | 分层探测默认路由、动态网关响应、4 独立公网 TCP 握手 (绕过代理)、DNS 解析、DHCP 状态、WinINET/WinHTTP 代理与 WLAN 驱动 |
| **[2]** | **安全修复** | 普通用户 | 极低 | 仅执行 `ipconfig /flushdns`，仅对确认使用 DHCP 的活动物理网卡续租；静态 IP 自动跳过，绝不执行 `/release` |
| **[3]** | **重连活动物理网卡** | 管理员 | 高风险 | 严格复核活动网卡 GUID 与硬件类型，警告并要求输入 `RESTART` 确认；采用 `Disable/Enable-NetAdapter` 硬件重启，并在 finally 中确保启用 |
| **[4]** | **深度重置 Winsock/TCP-IP** | 管理员 | 极高 (最终手段) | 全面扫描所有接口；若存在静态 IP (Dhcp=Disabled) 则默认拦截拒绝；需输入 `DEEP-RESET` 确认；完成后提示手动重启，绝不自动重启 |
| **[5]** | **清除 WinINET 代理恢复直连** | 普通用户 | 低风险 | 自动在 U 盘保存代理 JSON 快照，将当前用户 WinINET 设为直连并清除代理服务器地址；绝不触碰 WinHTTP |
| **[6]** | **从代理快照恢复 WinINET** | 普通用户 | 低风险 | 精确按照快照恢复每个键值 (存在则还原，不存在则删除)；支持按指针或自动匹配最新快照 |
| **[7]** | **导出第三方网络驱动** | 管理员 | 零风险 | 检查 U 盘可用空间，使用 PnPUtil 筛选并导出 DeviceClass=Net 的第三方驱动至 U 盘，生成 `driver-inventory.csv` |
| **[8]** | **生成诊断报告压缩包** | 普通用户 | 零风险 | 收集 ipconfig, 路由, 适配器, 事件日志等并脱敏打包；严禁导出明文 Wi-Fi 密码；WLAN report 显式可选 |
| **[0]** | **退出工具箱** | - | - | 退出程序 |

---

## 驱动恢复与离线安装指南

当在新电脑或重装系统后缺少网卡驱动时，可使用本工具导出的驱动进行离线安装：

1. 打开管理员权限的命令提示符 (CMD) 或 PowerShell。
2. 运行 Windows 原生 PnP 驱动添加命令（假设 U 盘盘符为 `X:`）：
   ```cmd
   pnputil /add-driver "X:\Network-Recovery-USB\output\drivers\*.inf" /subdirs /install
   ```
3. **技术要点**：
   - Windows 内部的硬件驱动签名排名机制依然有效。
   - 驱动恢复时应优先使用笔记本原厂 OEM 官方为该确切型号发布的驱动程序包。

---

## 文件完整性自检

在投入生产或应急使用前，可通过 PowerShell 自带的哈希命令比对文件完整性：

```powershell
Get-FileHash -Algorithm SHA256 Start-NetworkRecovery.cmd, NetworkRecovery.ps1, NetworkRecovery.Config.psd1, README.md, modules\*.psm1 | Format-Table -AutoSize
```

比对输出的 Hash 是否与根目录下的 `SHA256SUMS.txt` 完全一致。

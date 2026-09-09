# Windows 10/11 便携网络诊断与急救工具箱 (完全驻留于 U 盘独立版)

本工具箱是一套专为 Windows 10/11 笔记本与台式机设计的便携式网络急救与诊断套件。所有脚本、模块、快照与日志**完全驻留在 U 盘目录内**，拔掉 U 盘后不在操作系统中留下任何计划任务、服务、常驻进程或注册表启动项。

---

## 1. 快速启动指南

1. 将 U 盘插入任意 Windows 10/11 电脑。
2. 双击运行 U 盘根目录下的 `Start-NetworkRecovery.cmd`。
3. 工具将以标准用户权限启动交互式控制台，默认展示菜单。

---

## 2. 功能菜单说明

| 选项编号 | 功能名称 | 权限要求 | 关键技术机制与安全保障 |
| :--- | :--- | :--- | :--- |
| **[1]** | **只读网络诊断** | 标准用户 | 分 12 层全息探测（路由、物理/虚拟网卡、IPv6黑洞、节能状态、Wi-Fi链路质量、DHCP租约生命周期、NCSI探针、4个TCP直连握手、DNS解析、WinINET/WinHTTP代理、6大系统服务）。**绝对纯只读**。 |
| **[2]** | **安全修复** | 标准用户 | 执行 `ipconfig /flushdns`；对确认处于 DHCP 模式的活动物理网卡执行续租；**自动跳过静态 IP 接口**；**绝不执行 /release**；修复前后自动保存快照并比对。 |
| **[3]** | **重连活动物理网卡** | 管理员 (UAC) | 高风险操作。严格限制为诊断确认的同一个物理网卡；核验 InterfaceIndex 与 GUID；提示断网风险；必须输入 `RESTART` 精确确认；采用管道执行，`finally` 块中强制重新启用网卡；支持 `-WhatIf`。 |
| **[4]** | **深度重置协议栈** | 管理员 (UAC) | 最终手段。自动扫描全系统所有非 Loopback IPv4 接口（包含处于断开状态的网卡），**若发现任何静态 IP 接口则默认拒绝执行**；必须输入 `DEEP-RESET` 确认；重置 Winsock/IP/DNS；绝不执行破坏性的 `netcfg -d`；完成后提示手动重启，不强制自动重启。 |
| **[5]** | **代理改直连** | 标准用户 | 仅修改当前用户 WinINET (`HKCU:\...\Internet Settings`)；修改前将所有键值的 Present/Value 状态完整导出为 JSON 快照；更新相对路径指针；必须输入 `DIRECT` 确认；**绝不修改 WinHTTP 系统代理**。 |
| **[6]** | **从快照恢复代理** | 标准用户 | 读取最近有效代理快照；将 Present/Value 精确还原至当前用户 WinINET；必须输入 `RESTORE` 确认；支持 `-WhatIf`。 |
| **[7]** | **导出第三方网络驱动**| 管理员 (UAC) | 检查 U 盘可用空间 (>=500MB)；使用 `pnputil /export-driver` 仅备份第三方 `oem*.inf` 网络硬件驱动；生成 `driver-inventory.csv` 清单；不卸载、不删除系统驱动。 |
| **[8]** | **生成诊断脱敏压缩包**| 标准用户 | 收集路由、网卡、IP、DNS、系统服务、WLAN接口与事件日志；**绝不收集 Wi-Fi 明文密码 (无 key=clear)**；完整 WLAN 报告需显式确认；打包为 ZIP 并保存在 U 盘 `output\`。 |
| **[0]** | **退出** | 无 | 退出工具箱，释放资源。 |

---

## 3. 驱动备份与恢复说明

### 3.1 备份机制
本工具通过 Windows 原生 `pnputil` 工具枚举并仅导出 Class 为 Net 的第三方驱动程序（`oem*.inf`），备份保存在 U 盘 `output\drivers\` 目录下，并同步生成 `driver-inventory.csv`。

### 3.2 恢复方法
若目标电脑网卡驱动损坏或重装系统后缺少驱动，可在管理员权限命令行中执行以下命令进行离线恢复：

```cmd
pnputil /add-driver "X:\Network-Recovery-USB\output\drivers\*.inf" /subdirs /install
```
*(请将 `X:` 替换为当前 U 盘实际盘符)*

> **重要说明**：Windows 驱动签名与硬件排名机制仍然生效。若有笔记本 OEM 厂商提供的专用驱动，应优先使用官网原厂驱动。

---

## 4. 完整性校验说明

在部署或执行前，可使用 Windows 自带 PowerShell 命令核验工具文件哈希：

```powershell
Get-FileHash -Path "X:\Network-Recovery-USB\NetworkRecovery.ps1" -Algorithm SHA256
```

并比对根目录下的 `SHA256SUMS.txt`，确保脚本未被篡改。

---

## 5. 绝对安全红线与禁止事项

本工具箱严格遵守以下安全红线：
1. **零系统驻留**：不创建任何 Windows 计划任务、服务、注册表 Run 键或 ProgramData 文件夹。
2. **零破坏性重置**：严禁执行 `netcfg -d`、`delete-driver`、`Wi-Fi profile delete`、`Remove-NetRoute`、`Remove-NetIPAddress` 或清空防火墙规则。
3. **零隐私泄露**：严禁导出 Wi-Fi 明文密码（禁止 `key=clear`），严禁收集浏览器凭据或个人文件。
4. **完全相对路径**：所有脚本与批处理均使用 `$PSScriptRoot` 与 `%~dp0`，不依赖固定盘符，不向系统盘写入日志。

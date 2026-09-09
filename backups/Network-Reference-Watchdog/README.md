<!-- 来源: Claude Code, 2026-08-09; 2026-08-13 更新探测与拔网卡策略 -->

# 网络恢复看门狗 (auto_network_recovery.ps1 + manage_watchdog.ps1)

## 先看这一句：怎么启动

**永远只用这一条命令：**

```powershell
powershell -File "D:\agentNeural Network Knowledge Base\network\manage_watchdog.ps1" -Install
```

**绝对不要**再用 `powershell -file auto_network_recovery.ps1` 手动直接拉起脚本。
2026-08-09 当天，两个不同的 AI 会话各自这样手动起了一份，两份脚本互不知道对方
存在，各自独立判断"网络不通"、各自独立执行拔插网卡（`Disable-NetAdapter` +
`Enable-NetAdapter`），日志里 16:22 和 16:24 各触发一次，与用户报告的两次"突然断网"
时间点完全吻合——**看门狗自己才是那两次断网的真正原因**，不是路由器、不是驱动。

v2（当前版本）加了 Mutex 单实例锁 + 计划任务 `IgnoreNew` 双重保护，但这只能防止
"同时跑两份"，防不住"每次都手动起一份、忘了先看有没有已经在跑的"。所以规则很简单：
不要手动起，永远走 `manage_watchdog.ps1`。

## 这个看门狗解决什么问题

这台笔记本（MediaTek Wi-Fi 6E MT7922 无线网卡，无有线网口）在系统代理模式下跑
Clash Verge (verge-mihomo) + ProxyBridge。会导致"看起来没网"的情况分三种，根源
完全不同，需要不同的修法：

1. **Wi-Fi 链路真的断了**（网卡掉线、驱动省电模式关闭网卡）—— 需要重连网卡。
2. **广域网/宽带断了或路由器抖动** —— 网关 ping 可能失败，但这本身不代表网络坏了。
3. **代理节点超时，但 Wi-Fi 和宽带都是好的** —— 这是实测中最常见的情况（Clash Verge
   截图里一堆节点显示 Timeout，需要手动点测速图标才能恢复），跟网卡、路由器完全无关。

v1 脚本把这三种情况混为一谈，唯一判据是 `ping 192.168.0.1`（网关），一旦网关响应
慢就直接拔插网卡——用一个有噪声的信号触发最激进的动作，这也是它自己制造断网的
根本原因。

## v2 解决问题的方式

### 判据拆成 5 层，互相独立

| 层 | 检查内容 | 用途 |
|---|---|---|
| Layer 0 | `Get-NetAdapter` 状态是否 Up | 网卡被拔/被禁用时最先命中，最便宜 |
| Layer 1 | ping 网关 | **仅供参考**，不再单独触发任何恢复动作 |
| Layer 2 | 绕过代理，直连 **4 个**不同运营商、不同端口的公网地址做 TCP 探测（223.5.5.5:53、119.29.29.29:53、114.114.114.114:53、www.baidu.com:443） | 判断广域网是否真的不通；**4 个全部失败**才算 WAN 不通，任意一个通即视为 WAN 健康。2026-08-13 从 2 个目标改成 4 个——见下方"2026-08-13 探测重设计" |
| Layer 3 | 调用本地 mihomo API（`external-controller`，从 Clash Verge 的 `config.yaml` 运行时读取，不硬编码密钥），检查当前选中代理分组的活跃节点最近一次延迟测试是否有效 | 判断"代理节点坏了"这件事，跟链路/广域网分开处理 |
| Layer 4 | DNS 解析测试 | 诊断辅助，触发 flush DNS |

### 为什么网关 ping 失败不再直接拔网卡

网关响应慢常见于路由器繁忙或局域网内广播风暴，跟"电脑连不上外网"不是一回事。
v1 拿它当成唯一判据、直接执行最激进的动作（拔插网卡），相当于用一次路由器打嗝
去触发一次真实断网。v2 把它降级为参考信号：只有 Layer 0（网卡状态）或 Layer 2
（4 个独立公网目标全部无法连接）判定失败，并且连续达到 `-FailuresBeforeRecovery`
次（默认 6 次探测，约 90 秒）才会进入拔网卡流程，同时有独立的冷却时间
（`-LinkCooldownSeconds`，默认 180 秒）防止抖动期内反复拔插。

### 2026-08-13 拔网卡默认关闭（重要）

把"连续失败 N 次就拔网卡"这条规则，单独再关了一道总闸。**现在 `Reset-WlanAdapter`
默认完全不执行**，除非启动看门狗时显式加 `-AllowNicReset`（计划任务里默认不带）。

原因：统计到今天为止，看门狗累计执行了 51 次"LAST RESORT: reconnecting Wi-Fi
adapter"拔网卡（2026-08-09 加保护前的旧代码 + 2026-08-13 旧实例继续跑），**51 次
全部是误判**——每一次都在制造一次真实的"WiFi 断开"（Windows WLAN-AutoConfig 日志
对应 `Reason: 网络被驱动程序断开连接。`），历史准确率 **0/51**。也就是说，这台机器
上"拔网卡"这个动作**从来没有真正修好过网络，每一次都是它自己在制造断网**。

因此默认把它彻底关掉。网络真断时，看门狗现在只会：flush DNS → 通过 mihomo API
切健康节点 → 重启代理进程（仅当 mihomo API 挂了）。要恢复拔网卡能力，编辑
`manage_watchdog.ps1` 在 `-Argument` 里给 `auto_network_recovery.ps1` 追加
`-AllowNicReset`，再 `-Install` 一次。不建议——除非有明确证据说明这台机器的网卡
确实会卡死到非拔不可的程度。

### 2026-08-13 探测重设计（为什么从 2 目标改 4 目标）

旧 Layer 2 用 2 个目标，且**都是 53 端口**（223.5.5.5:53、1.1.1.1:53），TCP 连接
超时 2000ms。实测复现：在一个完全正常的网络上（网关 30/30 通、ping 0 丢包），连续
跑 40 轮探测，**有 2 轮两个目标同时超时，而且是连续的第 35、36 轮**——再差一轮就够
触发当时的 3 次失败阈值去拔网卡。根因是两个目标都是公共 DNS 的 53 端口，会被运营商
同时限流/丢包，不是网络真断了。

新设计：
- **4 个目标**：223.5.5.5:53（阿里 DNS）、119.29.29.29:53（DNSPod）、114.114.114.114:53（114DNS）、www.baidu.com:443（百度 HTTPS）——不同运营商、不同端口（53 + 443），同时被限流的概率大幅下降。
- **任意一个通即 WAN 健康**（`Test-PublicWan` 提前返回），不是"全失败才算失败"。
- **TCP 超时 2000ms → 5000ms**（`-TcpProbeTimeoutMs`），给慢握手留余地。
- **失败阈值 3 → 6**（`-FailuresBeforeRecovery`），约 90 秒连续真断才动作。
- 判定 WAN 不通时，新函数会逐个记下每个目标的结果（`All N WAN targets unreachable: ...`），事后能分辨"全网真不通"和"某个目标被限流"，不用靠猜。

同一套 40 轮实测，新设计 **0/40** 误判。

### 三条独立的恢复通道，各自冷却，互不阻塞

- **链路/广域网通道**（最重）：flush DNS → 拔插网卡。冷却 180 秒。
  **拔网卡默认关闭**（见上"2026-08-13 拔网卡默认关闭"），所以这条通道目前实际只
  会执行 flush DNS；网卡重连要靠显式 `-AllowNicReset`。
- **代理进程通道**：只有当 mihomo 控制 API 本身连不上（说明进程可能挂起/崩溃）
  才重启 clash-verge / verge-mihomo / ProxyBridge 整个代理栈。冷却 90 秒。
- **代理节点通道**（新增，最常用）：发现活跃节点超时，只调用 mihomo API 重测当前
  分组、切换到延迟最低的健康节点（`PUT /proxies/:group`）。纯 API 调用，不杀进程、
  不影响其他连接、不碰网卡。冷却 60 秒。

三条通道互相独立、按需触发，不再是"一根筋"从轻到重线性升级——代理节点超时不需要
排队等在网卡拔插后面，也不会顺带触发网卡拔插。

### 单实例保护（双重）

1. 脚本内部：命名 Mutex `Global\NetworkRecoveryWatchdog`，启动时拿不到锁立即退出。
   比 PID 文件可靠——进程崩溃时 Mutex 由系统自动释放，不会留下僵尸锁。
2. 计划任务：`MultipleInstances = IgnoreNew`，作为 Mutex 之外的第二层防线。

### 店铺住宅 IP 绝不轮换（最高优先级，2026-08-09 加入）

`UK-Residential-ISP` 这个分组是跨境电商店铺（BitBrowser 窗口 + shein/paypal/payoneer
后台）的固定英国住宅出口。**它的出口 IP 一旦被自动切换，等于店铺换了登录 IP，直接
触发平台关联风控，有封号风险。**

因此看门狗的"代理节点通道"做了三重限制：

1. 只处理自动型分组（`URLTest` / `Fallback` / `LoadBalance`）。`Selector` 类分组是
   人工固定选择，一律跳过——`UK-Residential-ISP` 和 `多宝极速网络` 都是 Selector。
2. 参数 `-ProtectedGroupRegex`（默认 `Residential|住宅|ISP|店铺|UK-Residential`）
   在扫描阶段就把命中的分组名剔除。
3. `Repair-MihomoGroup` 函数入口再查一次同一个正则，即使被误调用也会直接 return
   并记一行 `Skipping protected group ...`。

同样的保护也写进了 Clash Verge 的全局 `Script.js`（收紧测速间隔时跳过 `PROTECTED`
正则匹配的分组），两边独立生效。

第四层在路由规则上：**三份订阅**（CrossWall / 多宝 / 810fast）的 rules 覆写都把店铺和
收款域名（shein 系、geiwohuo、dotfashion、srmdata、paypal / payoneer / worldfirst /
stripe）直接指向 `UK-Residential-ISP`，**三份的域名集合逐条一致**，这样切换任何一份
订阅都不会悄悄换掉店铺出口。新增订阅时要先补覆写再切过去。细节和实测证据见
`clash\CONFIG-REPAIR-20260810.md` 的"问题 5"和"问题 6"。

还有一个容易忽略的入口：分组的 `include-all-proxies: true` 会把配置里**所有**代理
节点吸进该分组，包括英国住宅代理。用它的地方必须带
`exclude-filter` 且保留 `Residential`，否则住宅出口会落进 url-test / fallback 被自动
切换。见"问题 7"。

已实测验证：保护生效（2026-08-09 22:51）之后的日志里，`UK-Residential` 相关改动
**0 条**。（更早的几条 `Switched group 'UK-Residential-ISP'` 无害——该分组只有一个
成员，"切换"其实是重选同一个节点，出口 IP 没变过。）

### 日志滚动

`network_recovery.log` 超过约 5MB 自动滚动为 `.1` 备份，不会无限增长。

## 怎么启动 / 停止 / 查看状态 / 卸载

全部通过 `manage_watchdog.ps1`（需要管理员权限，因为拔插网卡需要管理员）：

```powershell
# 安装并启动（注册为当前用户开机自启的计划任务，任务名 NetworkRecoveryWatchdog）
powershell -File manage_watchdog.ps1 -Install

# 查看任务状态、当前 PID、最近 15 行日志
powershell -File manage_watchdog.ps1 -Status

# 只停止当前运行实例（计划任务保留，下次登录仍会自启）
powershell -File manage_watchdog.ps1 -Stop

# 彻底卸载（注销计划任务，不再自启）
powershell -File manage_watchdog.ps1 -Uninstall
```

## 不解决什么问题

- 不解决路由器/宽带本身的故障（光猫灯不亮、运营商线路问题）——这些只能人工处理。
- 不解决"代理节点全部超时、一个健康的都没有"的情况——这时脚本会记日志说明找不到
  健康节点，但不会帮你换订阅/换机场。
- 不做 `netsh winsock reset` / `netsh int ip reset` 这类协议栈重置——用户已确认
  这台电脑之前重置过网络协议、驱动省电模式也已经手动修复过（`LowPowerEnable=0`），
  这些不是当前问题的根源，脚本也不应该再动这些。

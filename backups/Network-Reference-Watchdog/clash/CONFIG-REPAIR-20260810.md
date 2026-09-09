<!-- 来源: Claude Code, 2026-08-10 -->

# Clash Verge 配置修复记录（多宝极速网络订阅）

2026-08-09 到 08-10 期间，`多宝极速网络` 这份订阅被上一个 codex 会话改坏，切过去
就整个断网。这份文档记录三个真实根因和修法，避免以后重踩。

## 结论速查

| 问题 | 症状 | 根因 | 已修 |
|---|---|---|---|
| 1 | 切到多宝订阅立刻整个断网 | 分组引用了订阅里不存在的节点 `🇭🇰香港03-hkt` | ✅ 改为 `香港01-hkt` |
| 2 | 所有节点全部 Timeout、代理完全不通 | 多宝订阅自带的 dns 段缺 `proxy-server-nameserver` | ✅ merge 覆写补上 |
| 3 | 订阅里 20 个节点，Clash 里只显示 8 个 | groups 覆写文件手工只列了 8 个 | ✅ 补全为 20 个 |
| 4 | 店铺英国住宅 IP 走不通 | proxies 覆写写成 `type: socks5`，该端口只收 HTTP CONNECT | ✅ 改回 `type: http` |
| 5 | （隐患，未爆）店铺流量会从机房 IP 出去 | 多宝 rules 覆写把店铺域名指向轮换分组；两份订阅保护的域名集合也不一致 | ✅ 两份都改为 `UK-Residential-ISP` 并对齐 |
| 6 | （隐患，未爆）**第三份订阅完全没有店铺保护** | `Clash_1777098548.yaml`（810fast）五个覆写全是空模板，一次点击就能切过去 | ✅ 补齐 proxies/groups/rules 三份覆写，与另两份对齐 |
| 7 | （定时炸弹）机场改一个节点名就会重演问题 1 | 多宝 groups 覆写把 20 个节点名写死，而该订阅每 24 小时自动更新 | ✅ 改用 `include-all-proxies` + `exclude-filter` 自动收录 |

## 涉及的文件

Clash Verge 的订阅不是单个文件，而是「远程订阅 + 5 个本地覆写文件」合成的。
多宝这一份（uid `RauXFVU32LJs`）对应：

```
%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\profiles\
  RauXFVU32LJs.yaml    远程订阅原文，会被自动更新覆盖，不要手改
  mkedFUTsd29x.yaml    merge  覆写  <- 修了问题 2
  pXkGwrEHmaNR.yaml    proxies 覆写 <- 修了问题 4
  gN43Zl8JU9UI.yaml    groups 覆写  <- 修了问题 1 和 3
  rJTAJcPcJxnQ.yaml    rules  覆写
  sByIqm6ZmctZ.js      script 覆写（空函数）
```

合成结果写到 `..\clash-verge.yaml`（运行时配置，mihomo 实际加载的就是它）。
**改覆写文件才是持久的**，直接改 `clash-verge.yaml` 会被下次生成覆盖。

对应关系在 `profiles.yaml` 里每个订阅的 `option:` 段。当前激活的订阅由
`profiles.yaml` 顶部的 `current:` 决定。

**这台机器上一共有 4 份配置，不是 2 份**（2026-08-10 下午才发现，见问题 6）：

| 名称 | uid | 类型 | rules 覆写 | proxies 覆写 | groups 覆写 |
|---|---|---|---|---|---|
| CrossWall (克洛斯) | `RDRP5LVtIFFW` | remote | `rxfQKJzG79KR` | `pgcNPteAXJwE` | `gBJjxLD0OUFs` |
| 多宝极速网络 | `RauXFVU32LJs` | remote | `rJTAJcPcJxnQ` | `pXkGwrEHmaNR` | `gN43Zl8JU9UI` |
| Clash_1777098548.yaml（810fast） | `R7g2wYtm4kED` | remote | `rjHVdS03Tfr4` | `pmWbcZrGoP9w` | `gE5SxBqayUtw` |
| 1（本地） | `L7pIEGLzFY8p` | local | `r2ibI4pGT3q6` | `p3US9Q1vNpt6` | `gBFfV1kBAjuM` |

前三份都是"点一下就能切"的，所以**店铺域名保护必须三份都有**。第四份是本地应急配置，
只有一个住宅节点 + `MATCH,UK-Residential-ISP`（全部流量走住宅），店铺安全但会烧
按流量计费的住宅带宽，只适合临时救急。

## 问题 1：引用不存在的节点 = 整份配置加载失败

`gN43Zl8JU9UI.yaml` 的三个分组都引用了 `🇭🇰香港03-hkt`，但订阅里只有
`香港01-hkt` / `香港02-hkt` / `香港01-AWS电信优化`。mihomo 对这种情况是**硬失败**，
不是跳过：

```
$ verge-mihomo -d <dir> -t
level=error msg="proxy group[0]: 故障转移: '🇭🇰香港03-hkt' not found"
configuration file test failed
```

整份配置加载不了 → 代理完全不工作 → 表现为"切过去就断网"。

**排查手法（不要靠猜）**：把覆写合成成一份完整 config，用 mihomo 自己的 `-t` 校验。
改完后再跑一次确认 `test is successful`。合成脚本思路：读远程订阅 → 按
`prepend`/`append`/`delete` 合入各覆写 → 换掉 `external-controller` 和 `mixed-port`
避免和生产实例撞端口 → dump 出来 `-t`。

## 问题 2：缺 proxy-server-nameserver → 所有节点假死

多宝订阅自带 dns 段用的是 fake-ip 模式，但**没有** `proxy-server-nameserver`。
后果：mihomo 解析节点服务器域名（`*.jiedddym.com` / `*.sevenka.top`）时也走 fake-ip，
拿到 `198.18.x.x` 这种假地址，连不上任何节点。日志长这样：

```
level=warning msg="[TCP] dial 多宝极速网络 ... error: failed to create session:
  dns resolve failed: couldn't find ip"
```

面板上表现为**所有节点全部 Timeout**，很容易误判成"机场跑路了"。实际用裸 TCP 探测
节点端口是秒通的：

```
52.198.235.68:33321 OK 14ms      # 日本02
54.64.195.220:33322 OK 11ms      # 日本01
54.65.81.222:14029  OK 9ms       # 马来02
54.251.8.133:28652  OK 1ms       # 马来01
```

修法：在 `mkedFUTsd29x.yaml`（merge 覆写）里补纯 IP 的国内 DNS，专门用于解析代理
服务器地址。CrossWall 那份订阅自带这一段，所以从来没犯这个毛病。

## 问题 3：groups 覆写把 20 个节点裁成 8 个

`gN43Zl8JU9UI.yaml` 的 `append` 段手工列了 8 个节点，注释说是"保持在一个小的、测过
的集合上"。代价是**另外 12 个可用节点全被排除**（香港01/02-AWS、新加坡01、台湾01、
越南02、美国01-04、英国01/02、美国02-HY2），这 8 个里的日本/新加坡一挂就没得切。

已补全为 20 个真实节点。故意排除的 4 个不是节点：

- `剩余流量：101.22 GB` / `距离下次重置剩余：5 天` / `套餐到期：2027-06-14`
  —— 机场用来显示套餐信息的假节点，地址 `127.0.0.1:65535`，永远连不通
- `使用前更新订阅，特殊时期` —— tuic 应急节点，面板实测红色不通

补全后实测（8 秒超时，`GET /group/故障转移/delay`）**18/20 活**，52–312ms；
只有两个台湾节点间歇性超时（第一轮测试时台湾01 是 132ms，所以也不是死的）。

> 后续（同日下午）：手工列 20 个节点名这个修法本身是个定时炸弹，已改为
> `include-all-proxies` 自动收录，见下面的**问题 7**。

## 问题 4：ProxyCheap 住宅代理是 HTTP，不是 SOCKS5

`pXkGwrEHmaNR.yaml` 里把 `UK-ProxyCheap-Residential-ISP` 写成 `type: socks5`，
实测该端口只接受 HTTP CONNECT：

```
curl --proxy http://...@92.113.216.80:42259    -> ip=92.113.216.80  code=200
curl --proxy socks5h://...@92.113.216.80:42259 -> code=000（握手失败）
```

写错会让**店铺流量整条断掉**。CrossWall 那份订阅的同名覆写写的是 `type: http`，
是对的，两边现在一致了。

## 问题 5：rules 覆写把店铺域名指向轮换分组

这条是隐患，不是已经爆掉的故障，但后果最严重。

多宝的 rules 覆写（`rJTAJcPcJxnQ.yaml`）12 条规则全部指向 `多宝极速网络` —— 那是个
Selector，成员是 20 个会轮换的机房节点。也就是说**一旦切到多宝这份订阅，shein /
geiwohuo / dotfashion 的店铺后台就从机房 IP 出去，而且换节点就换 IP**。店铺频繁更换
登录 IP 正是平台关联风控要抓的特征。

顺手发现第二个不一致：两份订阅保护的域名集合不一样。CrossWall 少了 SHEIN 供应商侧的
`dotfashion.cn` / `srmdata.com` / `srmdata-eur.com` / `sheingroup.net`，这些域名在
CrossWall 激活期间是从轮换机房节点出去的 —— 同一套店铺账号出现两个来源 IP。

修法：两份 rules 覆写都改成同一套，店铺+收款域名全部指向 `UK-Residential-ISP`，
外加 `DOMAIN-KEYWORD,shein/dotfashion/geiwohuo` 兜底（捕获 `shein.mx`、`shein.co.jp`
这类 suffix 漏掉的地区站），国内 1688/淘宝系走 DIRECT。

`bitbrowser.net` 故意不走住宅：那是比特浏览器客户端跟厂商通信（取授权、同步窗口
配置），不是店铺会话，没必要占用按流量计费的住宅带宽。

实测验证（生产实例 `/logs` 流里抓的真实路由判定）：

```
[TCP] --> www.shein.com:443      match DomainSuffix(shein.com)    using UK-Residential-ISP[UK-ProxyCheap-Residential-ISP]
[TCP] --> us.shein.com:443       match DomainSuffix(shein.com)    using UK-Residential-ISP[UK-ProxyCheap-Residential-ISP]
[TCP] --> www.dotfashion.cn:443  match DomainSuffix(dotfashion.cn) using UK-Residential-ISP[UK-ProxyCheap-Residential-ISP]
[TCP] --> www.1688.com:443       match DomainSuffix(1688.com)     using DIRECT
[TCP] --> www.bitbrowser.net:443 match DomainSuffix(bitbrowser.net) using 多宝极速网络[日本01]
```

## 问题 6：第三份订阅完全没有店铺保护（2026-08-10 下午发现）

修完问题 5 时我以为"两份订阅已对齐"就完事了。实际清点 `profiles.yaml` 才发现
**还有第三份远程订阅** `Clash_1777098548.yaml`（810fast，uid `R7g2wYtm4kED`），
它的五个覆写文件全是 Verge 生成的空模板：

```yaml
prepend: []
append: []
delete: []
```

也就是说它既没有住宅代理节点、也没有 `UK-Residential-ISP` 分组、更没有一条店铺规则。
它在界面里跟另两份并列，而且**看起来最划算**（剩余 3979 GB / 到期 2026-10-13），
最可能被误切。切过去之后店铺流量会被它自带的规则送到 31 个轮换机房节点上：

```
DOMAIN-KEYWORD,.us, 🌍国外流量（点击展开）        <- 命中 us.shein.com
RULE-SET,gfw / tld-not-cn,🌍国外流量（点击展开）   <- 命中 shein.com 等
MATCH,🌍国外流量（点击展开）                      <- 兜底全部走机房
```

已补齐三份覆写（`pmWbcZrGoP9w` 住宅节点 / `gE5SxBqayUtw` 分组 / `rjHVdS03Tfr4` 规则），
域名集合与另两份**逐条一致**。隔离实例（27897）实测路由判定：

```
[TCP] --> us.shein.com:443       match DomainSuffix(shein.com)     using UK-Residential-ISP[UK-ProxyCheap-Residential-ISP]  http=200
[TCP] --> www.dotfashion.cn:443  match DomainSuffix(dotfashion.cn) using UK-Residential-ISP[UK-ProxyCheap-Residential-ISP]
[TCP] --> www.paypal.com:443     match DomainSuffix(paypal.com)    using UK-Residential-ISP[UK-ProxyCheap-Residential-ISP]  http=302
[TCP] --> www.1688.com:443       match DomainSuffix(1688.com)      using DIRECT                                            http=200
```

顺带查清这份订阅的可用性，别指望它当主力：

- 分组 `🌍国外流量（点击展开）` 的**前三个成员是假节点**（`10086:443`，名字就叫
  "0不能用请到网站中查阅教程🚫"），而 Selector 默认选中第一个 —— 所以刚切过去时
  普通流量是全断的，必须先手动选一个真节点。
- 27 个真节点实测 **25 个活，但延迟 443–1906 ms**。对比：多宝 52–312 ms、
  CrossWall 178–359 ms。所以它是第三顺位备份，不是升级选项。

## 问题 7：groups 覆写写死节点名 = 定时炸弹

问题 1 和 3 的修法是把 20 个节点名手工列进 `gN43Zl8JU9UI.yaml`。那修好了当下，
但没修掉病根：多宝这份订阅 `allow_auto_update: true` / `update_interval: 1440`，
**每 24 小时自动拉一次远程订阅**。机场只要给某个节点加个 emoji、改个编号、换个后缀，
这里立刻又变成悬空引用 —— 又是"整份配置硬失败 → 断网"，而且发生在无人值守的时候。

改用 mihomo 的自动收录，不再写节点名：

```yaml
- name: 自动选择
  type: url-test
  include-all-proxies: true
  exclude-filter: "(剩余流量|距离下次重置|套餐到期|使用前更新订阅|官网|Residential|Nigeria)"
  url: http://www.gstatic.com/generate_204
  interval: 300
  tolerance: 50
```

`exclude-filter` 里两类词的作用完全不同，**都不能删**：

- `剩余流量|距离下次重置|套餐到期|官网|使用前更新订阅` —— 剔掉机场的假节点
  （`127.0.0.1:65535` 的套餐信息展示项，以及实测不通的 tuic 应急节点）。
- `Residential|Nigeria` —— **这是安全要求**。`include-all-proxies` 会把 proxies 段里
  的**全部**节点吸进来，包括 proxies 覆写补的英国住宅代理和全局 `Merge.yaml` 里的
  `Nigeria-HTTP`。住宅代理一旦落进 url-test / fallback，mihomo 自己就会按延迟切换它，
  等于店铺换登录 IP。

隔离实例实测（不是看 YAML，是查 `/proxies` 的真实成员）：

```
自动选择   (URLTest)  20 个成员   住宅/Nigeria: 无
故障转移   (Fallback) 20 个成员   住宅/Nigeria: 无
多宝极速网络 (Selector) 23 个成员（20 节点 + 自动选择 + 故障转移 + DIRECT）  住宅/Nigeria: 无
UK-Residential-ISP (Selector) 1 个成员：UK-ProxyCheap-Residential-ISP
```

节点数与订阅里的真实节点数一致（24 条 proxies − 3 个套餐信息 − 1 个 tuic = 20），
而且以后机场改名、加节点、删节点都不会再让配置加载失败。

CrossWall 那份不需要这么改：它的分组来自订阅自身，覆写只额外定义了
`UK-Residential-ISP` 一个分组，没有手写节点名。

## 坑：改了覆写文件，Clash Verge 不会自己重新生成

**Verge 不监听覆写文件的外部改动。** 用编辑器/脚本改完 `profiles\*.yaml` 之后：

- `clash-verge.yaml` 的 mtime 不变，`GET /rules` 拿到的还是旧规则
- 等 30 秒、60 秒都没用，不是延迟，是根本没有 watcher

三种让它生效的办法：

1. 在 Verge 界面里重新点一下当前订阅（或订阅更新），它会重新合成 —— 最省事，但要人操作
2. 重启 Clash Verge —— 会顺带把 `profiles.yaml` 按内存状态写回，注意别丢改动
3. 自己把改动补进 `clash-verge.yaml` 再调 mihomo 的 `PUT /configs?force=true`
   （body `{"path": "<clash-verge.yaml 绝对路径>", "payload": ""}`）热加载

本次用的是第 3 种：**只替换 rules 数组开头那段 prepend 块**（Verge 从 rules 覆写生成
的部分），文件其余内容一个字不动，这样 Verge 下次自己重新生成时结果一致，不会漂移。
加载前先在隔离目录用 `-t` 校验过同一份内容，失败就不落盘。备份在
`clash-verge.yaml.bak-20260810-rules`。

## 当前状态（2026-08-10 18:20 验证）

- 激活订阅：`CrossWall (克洛斯)`（`profiles.yaml` 的 `current: RDRP5LVtIFFW`，
  13:54 由用户在界面里切换）。
- 主端口 7897 出口：`216.227.169.5`（colo=LAX，CrossWall 美国节点；这个 IP 会随
  普通流量的节点切换而变，正常）
- 店铺桥 7898 出口：`92.113.216.80`（colo=LHR，固定英国住宅，全程未变）
- 生效规则数：66，开头 14 条店铺/收款 → `UK-Residential-ISP`，3 条关键字兜底，
  8 条国内 → DIRECT
- `UK-Residential-ISP` 分组：1 个成员，当前 = `UK-ProxyCheap-Residential-ISP`
- CrossWall 节点：`/group/.../delay` 实测 **16/16 全活**，178–359ms
- 看门狗计划任务 `NetworkRecoveryWatchdog`：Running，单条时间线，17 秒一跳

### 三份订阅的额度与到期（从 `profiles.yaml` 的 `extra` 段读，不是猜的）

| 订阅 | 已用 / 总量 | 剩余 | 到期 | 节点实测 |
|---|---|---|---|---|
| CrossWall (克洛斯) | 81.68 / 200 GB (40.8%) | 118.32 GB | 2026-10-23（还剩 73 天） | 16/16 活，178–359 ms |
| 多宝极速网络 | 18.78 / 120 GB (15.6%) | 101.22 GB | 2027-06-14（还剩 308 天） | 18/20 活，52–312 ms |
| 810fast | 20.24 / 4000 GB (0.5%) | 3979.76 GB | 2026-10-13（还剩 63 天） | 25/27 活，443–1906 ms |

**用户之前说"克洛斯马上要过期"，实际到期日是 2026-10-23，还有 73 天**，流量也还剩
一半多。所以不用急着切；真要切，多宝（到期最晚、延迟最低）是首选，810fast 只作
第三顺位（延迟高，且默认选中的是假节点）。三份现在都通过 `-t`、都保护同一组店铺域名。

三份订阅现在保护完全相同的一组店铺域名，**切换任何一份都不会悄悄改变店铺出口**。

### 测 7897 出口不要用 `https://1.1.1.1/cdn-cgi/trace`

CrossWall 这份订阅里有 `IPCIDR 1.1.1.1/32 -> CrossWall (克洛斯)`，走代理去 1.1.1.1:443
是不通的（会一直空返回），而且订阅还把 `ipapi.co` / `ipapi.is` / `ipwho.is` / `ip.sb`
全设成了 `REJECT-DROP`。**这不是故障**。测出口用域名版：

```
curl -x http://127.0.0.1:7897 https://www.cloudflare.com/cdn-cgi/trace
```

## 备份文件

改动前的原始版本都留在同目录，文件名带 `.bak-20260810`：

```
profiles.yaml.bak-20260810
profiles\pXkGwrEHmaNR.yaml.bak-20260810        多宝 proxies
profiles\gN43Zl8JU9UI.yaml.bak-20260810        多宝 groups（最初的 8 节点版, 含 香港03-hkt 悬空引用, 仅供对照）
profiles\rJTAJcPcJxnQ.yaml.bak-20260810        多宝 rules
profiles\rxfQKJzG79KR.yaml.bak-20260810        CrossWall rules
profiles\Script.js.bak-20260809
clash-verge.yaml.bak-20260810-rules            热加载 rules 前的运行时快照
clash-verge.yaml.bak-20260809-interval         （08-09 21:49，含 codex 删掉分组前的状态）
```

810fast 那三份覆写（`pmWbcZrGoP9w` / `gE5SxBqayUtw` / `rjHVdS03Tfr4`）原本就是
`prepend: [] / append: [] / delete: []` 的空模板，所以没有单独备份 —— 要还原就把
`prepend:` 改回 `[]`，每个文件的注释末尾都写了这一句。

## 校验脚本

`compose_validate.py`（本目录）—— 按 Verge 的语义把「远程订阅 + 全局 Merge +
5 个覆写」合成成一份完整 config，先自查悬空引用（分组成员、规则目标），再换掉端口
丢给 `verge-mihomo -t`。用法：

```bash
cd "D:\agentNeural Network Knowledge Base\network\clash"
python compose_validate.py RauXFVU32LJs        # 多宝
python compose_validate.py RDRP5LVtIFFW        # CrossWall
python compose_validate.py R7g2wYtm4kED        # 810fast
STAGE_RULES=<path> python compose_validate.py RDRP5LVtIFFW   # 先校验再落盘
```

`STAGE_RULES` 是为了**改动落到激活订阅之前先验一遍**，别拿生产配置试错。
临时目录用 `D:\OpenClaw-AgentOS\workspace\_mihomo_validate`，每次跑之前会清空。

## 给以后的智能体：改这些配置的规矩

1. **改覆写文件，不要改 `clash-verge.yaml`**，后者是生成物。唯一例外是"坑"那一节
   说的热加载手法，而且只允许替换 Verge 从覆写生成的那一段。
2. **改完必须用 `verge-mihomo -t` 校验**，不要只看 YAML 语法对不对。分组引用不存在的
   节点是硬失败，只有 mihomo 自己能查出来。校验需要把 `Country.mmdb` / `geoip.dat` /
   `geosite.dat` / `geoip.metadb` 一起复制到测试目录，否则它会去下载。
   直接用 `_compose_validate.py`，不用重新造轮子。
3. **要在隔离端口上起测试实例**（换掉 `external-controller` 和 `mixed-port`，
   并且 `listeners` 要整段删掉，否则和生产的 7898 桥撞端口），
   不要拿生产实例做实验；测完立刻 `Stop-Process` 收掉。
4. **`UK-Residential-ISP` 是店铺固定出口，绝不能自动切换**，理由见
   `README.md` 的"店铺住宅 IP 绝不轮换"一节。
5. **动 rules 覆写时，三份订阅要同步改**（CrossWall / 多宝 / 810fast）。店铺域名集合
   必须逐条一致，否则切换订阅等于给店铺换了来源 IP —— 这是问题 5 和问题 6 的教训。
   新增订阅时**先补这三份覆写再切过去**，不要先切了再补。
6. **不要在 groups 覆写里手写节点名**，用 `include-all-proxies: true` +
   `exclude-filter`，理由见问题 7。写 `exclude-filter` 时必须保留 `Residential`
   和 `Nigeria`，否则住宅出口会被吸进自动分组。
7. **改 `profiles.yaml` 前先退出 Clash Verge**，运行中的 Verge 会把内存里的状态写回
   去覆盖你的改动（全局 `Merge.yaml` 里有 `profile.store-selected: true`，
   它会持续回写每个订阅的 `selected:` 状态）。
8. **改完覆写文件记得让它生效**，见上面"坑"那一节 —— 光改文件不会自动生效，
   容易误判成"改了没用"。**例外**：改的是**非激活**订阅的覆写时不用做任何事，
   Verge 在用户切换到那份订阅时会自己重新合成。

# LanDetector 需求清单

> 目标：完整覆盖 LanScan 8.2.17（本机 `/Applications/LanScan.app`）的全部功能，提供更现代、更好看的原生 macOS 界面，并在识别能力、监控与工具上全面增强。纯 Swift / SwiftUI 原生应用，追求极致扫描速度。

## 一、LanScan 功能分析（逆向自 App 包资源、nib 与二进制字符串）

| 模块 | LanScan 现有能力 | 证据 |
|---|---|---|
| 网络接口 | 选择接口（en0/en5/bridge…），显示名称、IP/掩码、网关、本机 MAC | `interfaceSelectionPopup`、`selectedInterface.*` 绑定 |
| 公网信息 | 公网 IPv4 / IPv6、ISP、国家 | `LSPublicIpService`，ipify / ipinfo / ipwho.is / ident.me |
| IPv4 发现 | 整个子网或自定义 IP 区间（可保存多个区间） | `LSIpRangeTextField`、`LanScanCustomRanges` |
| 存活检测 | ICMP Ping（v4/v6，发现与保活两类 socket） | `LSPingSocket`、`ping4DiscoverySocket` |
| MAC 获取 | 读取 ARP / NDP 表（macOS 27 已被系统屏蔽，提示 "MAC address access is blocked"） | `ArpEntry`、nib 文案 |
| IPv6 | 本地链路 / 全局地址（含 secured 地址），仅限与 IPv4 网段关联的设备 | `arpScan6ThreadCode`、`ip6GlobalSecuredAddress` |
| 主机名 | DNS 反查、mDNS（Bonjour）、SMB/NetBIOS 名称与工作组 | "Hostname resolution - SMB, mDNS and DNS" |
| 厂商 | IEEE MA-L / MA-M / MA-S / IAB / CID 全部注册表 | `Mac_mal/mam/mas/iab/cid.plist` |
| 设备识别 (NDI) | 根据 Bonjour 服务 TXT 记录识别品牌 / 型号（Apple、Amazon、Samsung、Sonos、Bose、Roku、HP…） | `NDIEngine`、`_airplay/_raop/_googlecast/_hap/_sonos/_amzn-wplay/_printer…` |
| Apple 型号 | 型号标识符 → 营销名称（如 MacBookPro18,3） | `appleDeviceFilesById.json`（源自 AppleDB） |
| 端口扫描 | 最常见 N 个端口 / 全部 65535 / 自定义 | `portScanRadioButton*`、`TCPPorts.txt` |
| 扫描模式 | 单次扫描、无限实时扫描（Live Scan） | `startStopLiveLsMenu` |
| 结果列表 | 列：Ping、IPv4、IPv6 本地、IPv6 全局、MAC、厂商、主机名、DNS 名、mDNS 名、SMB 名、SMB 域、TCP 端口、识别、备注；可排序、可调整列宽顺序 | `id_*` 列标识 |
| 详情面板 | 选中设备显示全部字段 | `Show Details Pane` |
| 自定义 | 编辑主机名（自定义名称）、备注、自定义名称颜色、每设备自定义打开 URL | `editHostname`、`saveCustomUrlInDeviceDict` |
| 导入导出 | 导出结果 CSV(分号)/TSV/PSV；导入/导出自定义名称（软导入/硬导入） | `exportResultsIn*`、`soft/hardImportCustomNames` |
| 其他 | 搜索过滤、清空结果、复制 IP/MAC/主机名/厂商、浏览器打开、隐藏仅 IPv6 设备、放大缩小文字、打印、快捷键 | 菜单项 |

## 二、LanDetector 需求清单

优先级：**P0** = 首版必须（覆盖 LanScan）；**P1** = 首版增强；**P2** = 后续迭代。

### 1. 网络与接口
- [P0] 自动选择主接口，可切换所有可用 IPv4 接口（Wi-Fi / 以太网 / 雷雳网桥 / VPN 标注）
- [P0] 显示接口名、IP/前缀、子网范围、网关、本机 MAC、DNS 服务器
- [P0] 公网 IPv4 / IPv6、ISP、国家/城市（可在设置中关闭外网请求）
- [P0] 自动扫描整个子网；支持自定义 IP 区间（起止 IP 或 CIDR），可保存多个预设
- [P1] 网络变化（切换 Wi-Fi / 网线）自动检测并切换到对应网络的设备库

### 2. 发现与扫描引擎（速度优先）
- [P0] ICMP 扫描：非特权 ICMP socket，高速发包（/24 约 0.2 s 发完），记录 RTT
- [P0] ARP 获取 MAC：sysctl 优先，被系统屏蔽时回退调用 `/usr/sbin/arp -anl`，并用 ARP 条目的接收过期时间（Expire(I)）判断新鲜度，避免把过期缓存误判为在线
- [P0] IPv6：向 `ff02::1` 发组播 ICMPv6（本地链路源 + 全局源），读取 NDP 表关联 MAC
- [P0] mDNS：服务类型枚举 + 逐设备单播反查主机名 + 服务实例 SRV/TXT 解析
- [P0] NetBIOS：NBSTAT 查询获取 SMB 名称与工作组（及 MAC）
- [P0] DNS 反向解析（系统解析器，并发受限）
- [P1] SSDP / UPnP：M-SEARCH 发现，抓取设备描述 XML（友好名称、制造商、型号、设备类型）
- [P0] 所有探测并行、结果流式回传，UI 首个设备 < 0.5 s 出现；/24 完整扫描 ≈ 4–6 s
- [P0] 单次扫描 / 实时监控（可配置间隔），实时模式中下线设备自动标记离线

### 3. 设备识别（超越 NDI）
- [P0] IEEE 全量厂商库（MA-L / MA-M / MA-S / IAB / CID），离线查询
- [P0] 随机（本地管理）MAC 识别并标注"私有地址"
- [P0] Apple 型号标识符 → 营销名称（AppleDB，MIT）
- [P0] 多信号融合分类：Bonjour 服务/TXT（model、am、md、ty、rpMd、deviceid…）、UPnP、NetBIOS、主机名规则、厂商规则、开放端口 → 设备类型 + 型号 + 置信度
- [P0] 设备类型：路由器、电脑、笔记本、手机、平板、电视、流媒体盒、音箱、打印机、摄像头、NAS、游戏机、智能家居、IoT、手表、网络设备、服务器、虚拟机、未知
- [P1] 用户可手动覆盖设备类型

### 4. 端口扫描
- [P0] 预设：常用端口（约 150 个，面向局域网设备精选）、知名端口 1–1024、全部 1–65535、自定义（`22,80,8000-8100`）
- [P0] 非阻塞 connect + kqueue 高并发（默认 256 并发），可扫选中设备或全部设备
- [P0] 端口显示 IANA 服务名称与描述
- [P1] 对开放的 HTTP 端口抓取网页标题、对常见端口抓取 banner

### 5. 设备库与持久化
- [P0] 按网络（网关 MAC）分别保存设备库：首次发现、最后在线、历史名称
- [P0] 自定义名称、备注、自定义 URL、收藏、自定义类型
- [P0] 导入 / 导出自定义名称（软导入：冲突保留当前；硬导入：冲突覆盖）
- [P1] 延迟历史（迷你曲线）、在线状态时间线

### 6. 界面（SwiftUI，macOS 26 Liquid Glass）
- [P0] 三栏布局：侧边栏（网络卡片 + 智能分组 + 类型分组）/ 设备列表 / 检查器
- [P0] 表格视图：LanScan 全部列 + 类型、型号、延迟、首次/最后在线；可排序、可显示/隐藏列
- [P1] 卡片网格视图（大图标、名称、型号、状态）
- [P0] 检查器：设备头像、名称编辑、全部地址、主机名、服务列表、端口、识别信息、备注、快捷操作
- [P0] 搜索（名称/IP/MAC/厂商/型号/端口全文）、智能分组：全部 / 在线 / 离线 / 新设备 / 收藏
- [P0] 快捷操作：浏览器打开、SSH、SMB（Finder）、屏幕共享（VNC）、网络唤醒、复制 IP/MAC/名称/厂商
- [P0] 导出：CSV（逗号/分号）、TSV、PSV、JSON、Markdown
- [P0] 设置窗口：扫描、端口、隐私（公网查询）、通知、数据管理
- [P0] 快捷键：⌘R 扫描、⇧⌘R 实时监控、⌘K 清空、⌘F 搜索、⌥⌘I 检查器、⌘P 端口扫描、⌘+/⌘- 字号
- [P1] 菜单栏常驻图标：在线设备数、新设备、快速扫描
- [P1] 新设备通知（实时监控模式）
- [P0] 隐藏仅 IPv6 设备选项、深浅色自适应

### 7. 数据源（全部公开/开源）
| 数据 | 来源 | 许可 |
|---|---|---|
| MAC 厂商 | IEEE Registration Authority（standards-oui.ieee.org） | 公开 |
| 端口服务名 | IANA Service Name and Transport Protocol Port Number Registry | 公开 |
| Apple 型号 | AppleDB（api.appledb.dev / littlebyteorg/appledb） | MIT |
| DNS-SD 服务类型 | IANA 同一注册表（服务名） | 公开 |

数据通过 `Scripts/update_data.py` 生成紧凑 TSV 打包进应用；后续可在设置中在线更新。

### 8. 非功能需求
- 速度：冷启动 < 0.5 s 出窗；厂商库懒加载 < 100 ms；扫描全程不阻塞主线程，UI 批量合并刷新（≤ 10 次/秒）
- 原生：Swift 6 + SwiftUI + 少量 AppKit，无第三方依赖、无统计/追踪 SDK
- 权限：首次扫描触发"本地网络"授权；非沙盒（需调用 `arp` 与原始 socket）
- 本地化：界面中文

## 三、实施状态（2026-10-16）

已完成：上述全部 P0 项，以及 P1 中的 UPnP/SSDP、网络变化自动切换、手动覆盖设备类型、卡片视图、菜单栏图标、新设备通知、延迟曲线、HTTP 标题 / SSH 等 Banner 抓取、在线更新厂商库、多个自定义 IP 区间预设（工具栏切换即扫描，旧版单个区间自动迁移）、设备在线时间线（每次完整扫描记录一次，约 30 天 / 500 个采样，检查器显示在线率）。

尚未实现 / 后续迭代：
- 打印（可用导出 Markdown / CSV 代替）
- 可选的特权助手：BPF 原生 ARP 扫描与被动监听（无需依赖系统 ARP 表）

已验证的平台事实：macOS 27 对非 Developer ID 签名的进程隐藏 ARP/NDP 邻居表并把本机 MAC 掩码为 `02:00:00:00:00:00`；LanDetector 以 Developer ID 签名，sysctl 不可用时回退调用 `/usr/sbin/arp -anl`，本机 MAC 通过 IOKit 读取。

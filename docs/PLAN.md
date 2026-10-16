# LanDetector 实施计划

## 技术选型
- Swift 6.x、SwiftUI（macOS 26+，Liquid Glass），少量 AppKit（保存面板、剪贴板、打开 URL）
- 工程：XcodeGen（`project.yml` 为唯一事实来源）+ 本地 Swift Package `LanDetectorKit`（核心逻辑，可用 `swift build` / `swift test` 独立迭代）
- 附带命令行工具 `landetector-cli`：直接在终端跑扫描，便于调试引擎
- 无第三方依赖

## 目录结构
```
LanDetector/
├── project.yml                 XcodeGen 配置
├── Scripts/update_data.py      下载 IEEE / IANA / AppleDB 并生成数据文件
├── Packages/LanDetectorKit/
│   ├── Sources/LanDetectorKit/
│   │   ├── Net/        IPv4Address, MACAddress, NetworkInterface, UDPSocket, ARPTable, NDPTable
│   │   ├── Probes/     ICMPSweeper, ICMPv6Prober, MDNSProber, DNSMessage, NetBIOSProber,
│   │   │               SSDPProber, UPnPFetcher, ReverseDNS, PortScanner, WakeOnLAN, PublicIPService
│   │   ├── Data/       OUIDatabase, PortDatabase, AppleModelDatabase, CommonPorts
│   │   ├── Model/      Device, DeviceKind, BonjourService, UPnPInfo, NetBIOSInfo
│   │   ├── Identify/   DeviceClassifier
│   │   ├── Scan/       ScanEngine, ScanEvent, ScanOptions
│   │   └── Resources/  oui.tsv, ports.tsv, apple-models.tsv
│   ├── Sources/landetector-cli/
│   └── Tests/LanDetectorKitTests/
└── LanDetector/                应用（SwiftUI）
    ├── App/      LanDetectorApp, AppModel, Commands
    ├── Store/    DeviceStore（按网络持久化 JSON）
    ├── Views/    Sidebar, DeviceTable, DeviceGrid, Inspector, NetworkHeader, PortScanSheet, Settings, MenuBar
    └── Support/  Exporter, Actions, Formatters
```

## 扫描引擎流程（并行流水线）
```
t=0      ICMP 扫全网段（2 轮）──┐   ICMPv6 ff02::1（链路源/全局源）   SSDP M-SEARCH   mDNS 服务枚举
         ARP 轮询（每 400 ms）──┤
发现 IP ─▶ 立即派发：NetBIOS NBSTAT、mDNS 单播（反查 + 服务枚举）、DNS 反查
SSDP 响应 ─▶ 抓取 UPnP XML
mDNS 服务 PTR ─▶ SRV/TXT 解析
结束     最后一次 ARP + NDP 读取 → 计算在线状态 → finished
```
- 所有事件通过 `AsyncStream<ScanEvent>` 流式输出；`AppModel` 以 ~100 ms 节拍批量合并进设备列表
- 设备主键：MAC（无 MAC 时用 IP）；随机 MAC 设备同样以 MAC 为键

## 里程碑
1. **M1 骨架**：XcodeGen 工程、Package、数据脚本与数据文件、App 图标
2. **M2 引擎**：接口/网关、ICMP、ARP（含 arp 回退）、NDP、mDNS、NetBIOS、DNS、SSDP/UPnP、端口扫描、WOL、公网 IP；CLI 验证
3. **M3 识别**：厂商库、Apple 型号库、分类器
4. **M4 UI**：主窗口三栏、表格/网格、检查器、搜索与分组、工具栏、设置、导出、快捷键、菜单栏
5. **M5 持久化与监控**：设备库、自定义名称导入导出、实时监控与离线判定、新设备通知
6. **M6 打磨**：性能（批量刷新、懒加载）、构建验证、实际网络测试

## 风险与对策
| 风险 | 对策 |
|---|---|
| macOS 27 屏蔽 IPv4 ARP sysctl | 自动回退到 `/usr/sbin/arp -anl`；同时用 NDP、NetBIOS、AirPlay `deviceid` 补全 MAC |
| ARP 缓存过期条目误判在线 | 解析 Expire(I)（接收过期），只把新鲜条目或有 ICMP 回应的设备判为在线 |
| 本地网络隐私授权 | Info.plist 提供 `NSLocalNetworkUsageDescription` / `NSBonjourServices`；使用稳定签名避免反复授权 |
| 大网段（/16）扫描 | 默认上限 4096 主机，超出时提示并允许自定义区间 |

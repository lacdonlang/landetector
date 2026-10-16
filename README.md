# LanDetector

原生 macOS 局域网扫描器，完整覆盖 LanScan 的功能，并在识别能力、界面和监控上全面增强。
Swift 6 + SwiftUI（macOS 26 Liquid Glass），无任何第三方依赖或统计 SDK。

## 功能

| 能力 | LanScan | LanDetector |
|---|---|---|
| IPv4 子网 / 自定义区间扫描 | ✓ | ✓ 约 4 秒扫完 /24，首个结果 < 0.1 秒 |
| ARP / MAC 获取 | ✓（macOS 27 被系统屏蔽） | ✓ sysctl + `arp` 回退，按过期时间判断新鲜度 |
| ICMP 存活 + 延迟 | ✓ | ✓ 延迟曲线、持续 Ping |
| IPv6 本地 / 全局地址 | ✓ | ✓ 组播发现 + NDP + EUI-64 反推 MAC |
| DNS / mDNS / SMB 主机名 | ✓ | ✓ |
| 厂商（IEEE 全部注册表） | ✓ | ✓ 可在线更新 |
| 设备识别 (NDI) | 付费、按期购买 | ✓ Bonjour TXT + AppleDB 型号 + UPnP + NetBIOS + 主机名 + 厂商 + 端口 + Banner 多信号融合 |
| UPnP / SSDP | ✗ | ✓ 友好名称、制造商、型号 |
| Bonjour 服务列表 | ✗ | ✓ 含 TXT 记录 |
| 端口扫描 | ✓ | ✓ kqueue 高并发、IANA 服务名、HTTP 标题 / SSH 等 Banner |
| 实时监控 | ✓ | ✓ 离线判定、新设备通知、菜单栏常驻 |
| 设备库 | ✗ | ✓ 按网络持久化：首次发现、最后在线、历史 |
| 自定义名称 / 备注 / 网址 | ✓ | ✓ 另有收藏、手动指定类型 |
| 导入导出自定义名称 | ✓ 软/硬导入 | ✓ 软/硬导入 |
| 导出结果 | CSV/TSV/PSV | CSV（逗号/分号）/TSV/PSV/JSON/Markdown |
| 快捷操作 | 浏览器打开 | 网页、SSH、SMB、屏幕共享、网络唤醒、复制 |
| 界面 | 单表格 | 侧边栏分组 + 表格/卡片双视图 + 检查器，深浅色 |

## 构建

需要 Xcode 26+（开发于 Xcode 27 / macOS 27）与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
Scripts/build.sh --open
```

或 `xcodegen generate` 后用 Xcode 打开 `LanDetector.xcodeproj`。`project.yml` 是工程的唯一来源，新增文件后需重新生成。

**签名**：macOS 27 只向 Developer ID 签名的进程开放 ARP/NDP 表里的 MAC 地址，因此 Debug 与 Release 都使用 `Developer ID Application` 证书签名（`project.yml` 中的 `DEVELOPMENT_TEAM`）。换用其他证书时请同步修改；ad-hoc 签名的构建能扫描，但拿不到 MAC。

首次扫描时系统会请求"本地网络"权限，需要允许。

## 命令行调试

核心引擎位于本地 Swift Package `Packages/LanDetectorKit`，附带命令行工具：

```bash
Scripts/cli.sh scan --verbose
```

```bash
Scripts/cli.sh ports 192.168.1.1 common
```

```bash
cd Packages/LanDetectorKit && swift test
```

Debug 构建内置两个由环境变量开启的自检钩子（`LanDetector/Support/DebugSnapshot.swift`）：

- `LANDETECTOR_SNAPSHOT_DIR=<目录>`：依次切换列表 / 卡片 / 深色模式并把窗口渲染成 PNG（无需屏幕录制权限；玻璃材质的侧栏与检查器渲染不出来）。
- `LANDETECTOR_RESIZE_TEST=1`（可加 `LANDETECTOR_CHAOS=1`）：反复缩放窗口并切换视图与检查器，用于回归 SwiftUI 布局循环崩溃。详情列内容必须保持 `idealWidth: 0`，否则检查器打开时窗口变窄会触发 AppKit "Update Constraints" 死循环。

```bash
LANDETECTOR_RESIZE_TEST=1 LANDETECTOR_CHAOS=1 build/DerivedData/Build/Products/Debug/LanDetector.app/Contents/MacOS/LanDetector
```

## 数据来源（全部公开 / 开源）

| 数据 | 来源 | 许可 |
|---|---|---|
| MAC 厂商 | IEEE Registration Authority（MA-L / MA-M / MA-S / IAB / CID） | 公开 |
| 端口服务名 | IANA Service Name and Transport Protocol Port Number Registry | 公开 |
| Apple 型号 | [AppleDB](https://appledb.dev) | MIT |

更新内置数据：`python3 Scripts/update_data.py`。应用内也可在 设置 ▸ 数据 中在线更新厂商库。

## 目录

```
project.yml                 XcodeGen 工程定义
LanDetector/                SwiftUI 应用（模型、视图、持久化、导出）
Packages/LanDetectorKit/    扫描引擎、协议探测、识别、数据库（+ CLI 与测试）
Scripts/                    数据生成、图标生成、构建脚本
docs/                       需求清单与实施计划
```

# 开发

[English](../en/DEVELOPMENT.md) · **简体中文**

```
project.yml                 XcodeGen 工程定义（LanDetector.xcodeproj 的唯一来源）
LanDetector/                SwiftUI 应用：模型、视图、持久化、导出、在线更新
Packages/LanDetectorKit/    扫描引擎、协议探测、识别、数据库，另含命令行工具与测试
Scripts/                    构建、发布、截图与数据脚本
docs/                       需求、计划、发布与本指南，中英文各一份
```

## 命令行工具与测试

扫描引擎位于本地 Swift Package `Packages/LanDetectorKit`，附带 `landetector-cli`。`Scripts/cli.sh` 会构建它并用 Developer ID 签名（否则 macOS 27 会隐藏 MAC 地址）：

```bash
Scripts/cli.sh scan --verbose
```

```bash
Scripts/cli.sh scan --range 192.168.77.1/24 --dns 192.168.99.1
```

```bash
Scripts/cli.sh ports 192.168.1.1 common
```

```bash
swift test --package-path Packages/LanDetectorKit
```

## 翻译

源语言是英文，简体中文放在 String Catalog 中：`LanDetector/Localizable.xcstrings`（应用）、`LanDetector/InfoPlist.xcstrings`（本地网络权限提示）与 `Packages/LanDetectorKit/Sources/LanDetectorKit/Localizable.xcstrings`（设备类型、服务、端口）。面向用户的文字用英文写：传给 `Text`、`Button`、`Label` 等的字面量 SwiftUI 会自动本地化；最终成为 `String` 的文字要用 `String(localized:)`（包内用 `String(localized:bundle: .module)`，表格里的条目用 `localized(_:)`）。构建时 Xcode 会把新字符串加入 Catalog，可直接在其中翻译，也可以导出再导入：

```bash
xcodebuild -exportLocalizations -project LanDetector.xcodeproj -localizationPath build/loc -exportLanguage zh-Hans
```

## 截图

`Scripts/screenshots.sh` 让 Debug 构建显示一个虚构的家庭网络（`LANDETECTOR_DEMO=1`，见 `LanDetector/Support/DemoNetwork.swift`），按每种语言与外观截取主窗口，存到 `docs/images/<语言>/<外观>/`。期间不会扫描也不会保存任何东西。截图经由 ScreenCaptureKit，玻璃材质的侧栏与检查器与屏幕上一致。

```bash
Scripts/screenshots.sh
```

## 调试钩子

Debug 构建内置几个由环境变量开启的自检（`LanDetector/Support/DebugSnapshot.swift`）：

- `LANDETECTOR_SNAPSHOT_DIR=<目录>`：依次切换列表、卡片与深色模式，把窗口渲染成 PNG，无需任何权限（玻璃材质的侧栏与检查器渲染不出来）。
- `LANDETECTOR_GALLERY_DIR=<目录>`：把侧栏、检查器（本机 / 网关 / 其他设备，深浅色）、设置各页、端口扫描面板与菜单栏面板分别放进普通离屏窗口渲染。
- `LANDETECTOR_WIDTH_TEST=1`：在列表与卡片视图中依次选中每台设备并记录各栏宽度，检查器宽度必须始终不变。
- `LANDETECTOR_TOOLBAR_TEST=1`：记录每个工具栏项位于哪一栏（检查器显示与隐藏各一次），并验证在搜索框输入能筛选列表、⌘F 能聚焦搜索框。
- `LANDETECTOR_RANGE_TEST=1`：选中一个跨路由的范围后启动，切到整个子网再切回来，记录每次显示的设备库与在线设备。
- `LANDETECTOR_RESIZE_TEST=1`（可加 `LANDETECTOR_CHAOS=1`）：反复缩放窗口并切换视图与检查器，用于发现 SwiftUI 布局循环。详情列内容必须保持 `idealWidth: 0`，否则检查器打开时窗口变窄会让 AppKit 陷入 “Update Constraints” 死循环。

```bash
LANDETECTOR_RESIZE_TEST=1 LANDETECTOR_CHAOS=1 build/DerivedData/Build/Products/Debug/LanDetector.app/Contents/MacOS/LanDetector
```

Debug 运行会读写你真实的设备库与偏好设置，请先备份 `~/Library/Application Support/LanDetector/Networks`。

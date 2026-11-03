# Development

**English** · [简体中文](../zh-CN/DEVELOPMENT.md)

```
project.yml                 XcodeGen project definition (the source of truth for LanDetector.xcodeproj)
LanDetector/                SwiftUI app: model, views, persistence, export, updates
Packages/LanDetectorKit/    Scan engine, protocol probes, identification, databases, plus a CLI and tests
Scripts/                    Build, release, screenshot and data scripts
docs/                       Requirements, plan, releasing and this guide, in English and Chinese
```

## Command-line tool and tests

The scan engine lives in the local Swift package `Packages/LanDetectorKit`, together with `landetector-cli`. `Scripts/cli.sh` builds it and signs it with the Developer ID, without which macOS 27 hides MAC addresses:

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

## Translations

English is the source language; Simplified Chinese lives in String Catalogs: `LanDetector/Localizable.xcstrings` (the app), `LanDetector/InfoPlist.xcstrings` (the local network permission prompt) and `Packages/LanDetectorKit/Sources/LanDetectorKit/Localizable.xcstrings` (device types, services, ports). Write user-facing text in English: SwiftUI picks up literals passed to `Text`, `Button`, `Label` and the like; text that ends up in a `String` needs `String(localized:)` (in the package, `String(localized:bundle: .module)`, or `localized(_:)` for entries of a table). Xcode adds new strings to the catalogs when building; translate them there, or export and import them:

```bash
xcodebuild -exportLocalizations -project LanDetector.xcodeproj -localizationPath build/loc -exportLanguage zh-Hans
```

## Screenshots

`Scripts/screenshots.sh` runs the Debug build on a made-up home network (`LANDETECTOR_DEMO=1`, see `LanDetector/Support/DemoNetwork.swift`) and captures the main window in each language and appearance into `docs/images/<language>/<appearance>/`. Nothing is scanned or saved. The capture goes through ScreenCaptureKit, so the glass sidebar and inspector come out as on screen.

```bash
Scripts/screenshots.sh
```

## Debug hooks

Debug builds have a few self-tests, started with environment variables (`LanDetector/Support/DebugSnapshot.swift`):

- `LANDETECTOR_SNAPSHOT_DIR=<dir>`: switches between list, cards and dark mode and renders the window to PNG without any permission (the glass sidebar and inspector don't render).
- `LANDETECTOR_GALLERY_DIR=<dir>`: renders the sidebar, the inspector (this Mac, gateway, other devices; light and dark), the settings pages, the port scan sheet and the menu bar panel in plain offscreen windows.
- `LANDETECTOR_WIDTH_TEST=1`: selects every device in list and card view and logs the column widths; the inspector's width must never change.
- `LANDETECTOR_TOOLBAR_TEST=1`: logs which column each toolbar item sits over (inspector shown and hidden) and checks that typing in the search field filters the list and ⌘F focuses it.
- `LANDETECTOR_RANGE_TEST=1`: with a range behind a router selected, switches to the entire subnet and back and logs the store shown and its online devices.
- `LANDETECTOR_RESIZE_TEST=1` (optionally with `LANDETECTOR_CHAOS=1`): resizes the window repeatedly while switching views and the inspector, to catch SwiftUI layout loops. The detail column's content must keep `idealWidth: 0`, or a narrowing window with the inspector open sends AppKit into an endless "Update Constraints" loop.

```bash
LANDETECTOR_RESIZE_TEST=1 LANDETECTOR_CHAOS=1 build/DerivedData/Build/Products/Debug/LanDetector.app/Contents/MacOS/LanDetector
```

Debug runs read and write your real device stores and preferences – back up `~/Library/Application Support/LanDetector/Networks` first.

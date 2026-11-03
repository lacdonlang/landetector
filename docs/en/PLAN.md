# LanDetector Implementation Plan

**English** · [简体中文](../zh-CN/PLAN.md)

## Technology choices
- Swift 6.x, SwiftUI (macOS 26+, Liquid Glass), a little AppKit (save panels, pasteboard, opening URLs)
- Project: XcodeGen (`project.yml` is the single source of truth) + a local Swift Package `LanDetectorKit` (core logic that can be iterated on independently with `swift build` / `swift test`)
- Ships a command-line tool, `landetector-cli`, that runs scans straight from the terminal for debugging the engine
- No third-party dependencies

## Directory layout
```
LanDetector/
├── project.yml                 XcodeGen configuration
├── Scripts/update_data.py      Downloads IEEE / IANA / AppleDB and generates the data files
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
└── LanDetector/                The app (SwiftUI)
    ├── App/      LanDetectorApp, AppModel, Commands
    ├── Store/    DeviceStore (per-network JSON persistence)
    ├── Views/    Sidebar, DeviceTable, DeviceGrid, Inspector, NetworkHeader, PortScanSheet, Settings, MenuBar
    └── Support/  Exporter, Actions, Formatters
```

## Scan engine flow (parallel pipeline)
```
t=0      ICMP sweep of the whole subnet (2 passes) ──┐   ICMPv6 ff02::1 (link-local / global source)   SSDP M-SEARCH   mDNS service enumeration
         ARP polling (every 400 ms) ─────────────────┤
IP found ─▶ dispatch immediately: NetBIOS NBSTAT, mDNS unicast (reverse lookup + service enumeration), reverse DNS
SSDP response ─▶ fetch UPnP XML
mDNS service PTR ─▶ resolve SRV/TXT
end      final ARP + NDP read → compute online status → finished
```
- Every event is streamed through `AsyncStream<ScanEvent>`; `AppModel` merges them into the device list in batches on a ~100 ms tick
- Device primary key: MAC (IP when there is no MAC); devices with randomized MACs are keyed by MAC as well

## Milestones
1. **M1 Skeleton**: XcodeGen project, Package, data script and data files, app icon
2. **M2 Engine**: interface/gateway, ICMP, ARP (including the arp fallback), NDP, mDNS, NetBIOS, DNS, SSDP/UPnP, port scanning, WOL, public IP; verified with the CLI
3. **M3 Identification**: vendor database, Apple model database, classifier
4. **M4 UI**: three-column main window, table/grid, inspector, search and groups, toolbar, settings, export, keyboard shortcuts, menu bar
5. **M5 Persistence and monitoring**: device library, custom name import/export, live monitoring and offline detection, new device notifications
6. **M6 Polish**: performance (batched refreshes, lazy loading), build verification, testing on real networks

## Risks and mitigations
| Risk | Mitigation |
|---|---|
| macOS 27 blocks the IPv4 ARP sysctl | Fall back automatically to `/usr/sbin/arp -anl`; also fill in MACs from NDP, NetBIOS and the AirPlay `deviceid` |
| Stale ARP cache entries mistaken for online devices | Parse Expire(I) (receive expiry) and only treat fresh entries, or devices that answered ICMP, as online |
| Local Network privacy permission | Info.plist provides `NSLocalNetworkUsageDescription` / `NSBonjourServices`; use a stable signature to avoid repeated permission prompts |
| Scanning large subnets (/16) | Default cap of 4096 hosts; beyond that, show a notice and allow a custom range |

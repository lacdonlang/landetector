# LanDetector Requirements

**English** · [简体中文](../zh-CN/REQUIREMENTS.md)

> Goal: fully cover every feature of LanScan 8.2.17 (the local copy at `/Applications/LanScan.app`), offer a more modern, better-looking native macOS interface, and go well beyond it in device identification, monitoring and tools. A pure Swift / SwiftUI native app that aims for the fastest possible scans.

## I. LanScan feature analysis (reverse-engineered from the app bundle's resources, nibs and binary strings)

| Module | What LanScan does today | Evidence |
|---|---|---|
| Network interface | Pick the interface (en0/en5/bridge…); shows name, IP/netmask, gateway, local MAC | `interfaceSelectionPopup`, `selectedInterface.*` bindings |
| Public info | Public IPv4 / IPv6, ISP, country | `LSPublicIpService`, ipify / ipinfo / ipwho.is / ident.me |
| IPv4 discovery | Whole subnet or custom IP ranges (multiple ranges can be saved) | `LSIpRangeTextField`, `LanScanCustomRanges` |
| Liveness check | ICMP ping (v4/v6, separate sockets for discovery and keep-alive) | `LSPingSocket`, `ping4DiscoverySocket` |
| MAC lookup | Reads the ARP / NDP tables (blocked by the system on macOS 27, showing "MAC address access is blocked") | `ArpEntry`, nib strings |
| IPv6 | Link-local / global addresses (including secured addresses), only for devices tied to the IPv4 subnet | `arpScan6ThreadCode`, `ip6GlobalSecuredAddress` |
| Hostname | Reverse DNS, mDNS (Bonjour), SMB/NetBIOS name and workgroup | "Hostname resolution - SMB, mDNS and DNS" |
| Vendor | All IEEE MA-L / MA-M / MA-S / IAB / CID registries | `Mac_mal/mam/mas/iab/cid.plist` |
| Device identification (NDI) | Identifies brand / model from Bonjour service TXT records (Apple, Amazon, Samsung, Sonos, Bose, Roku, HP…) | `NDIEngine`, `_airplay/_raop/_googlecast/_hap/_sonos/_amzn-wplay/_printer…` |
| Apple models | Model identifier → marketing name (e.g. MacBookPro18,3) | `appleDeviceFilesById.json` (derived from AppleDB) |
| Port scan | Top N most common ports / all 65535 / custom | `portScanRadioButton*`, `TCPPorts.txt` |
| Scan modes | Single scan, continuous live scan (Live Scan) | `startStopLiveLsMenu` |
| Results list | Columns: Ping, IPv4, IPv6 link-local, IPv6 global, MAC, Vendor, Hostname, DNS name, mDNS name, SMB name, SMB domain, TCP ports, Identification, Notes; sortable, with adjustable column width and order | `id_*` column identifiers |
| Details pane | Shows every field of the selected device | `Show Details Pane` |
| Customization | Edit hostname (custom name), notes, custom name color, per-device custom URL to open | `editHostname`, `saveCustomUrlInDeviceDict` |
| Import / export | Export results as CSV (semicolon) / TSV / PSV; import / export custom names (soft import / hard import) | `exportResultsIn*`, `soft/hardImportCustomNames` |
| Other | Search filter, clear results, copy IP/MAC/hostname/vendor, open in browser, hide IPv6-only devices, enlarge/shrink text, print, keyboard shortcuts | Menu items |

## II. LanDetector requirements

Priority: **P0** = required for the first release (LanScan parity); **P1** = first-release enhancements; **P2** = later iterations.

### 1. Network and interfaces
- [P0] Pick the primary interface automatically; switch between all available IPv4 interfaces (Wi-Fi / Ethernet / Thunderbolt Bridge / VPN labeled as such)
- [P0] Show interface name, IP/prefix, subnet range, gateway, local MAC, DNS servers
- [P0] Public IPv4 / IPv6, ISP, country/city (outbound requests can be turned off in Settings)
- [P0] Scan the whole subnet automatically; support custom IP ranges (start/end IP or CIDR), with multiple saved presets
- [P1] Detect network changes (switching Wi-Fi / plugging in a cable) and switch to that network's device library automatically

### 2. Discovery and scan engine (speed first)
- [P0] ICMP sweep: unprivileged ICMP socket, fast sending (a /24 is fully sent in about 0.2 s), records RTT
- [P0] MAC via ARP: sysctl first; when the system blocks it, fall back to running `/usr/sbin/arp -anl`, and use the ARP entry's receive expiry (Expire(I)) to judge freshness, so stale cache entries are not mistaken for online devices
- [P0] IPv6: send multicast ICMPv6 to `ff02::1` (from both a link-local and a global source), read the NDP table to associate MACs
- [P0] mDNS: service type enumeration + per-device unicast reverse hostname lookup + SRV/TXT resolution of service instances
- [P0] NetBIOS: NBSTAT queries for SMB name and workgroup (and MAC)
- [P0] Reverse DNS (system resolver, limited concurrency)
- [P1] SSDP / UPnP: M-SEARCH discovery, fetch the device description XML (friendly name, manufacturer, model, device type)
- [P0] All probes run in parallel and stream results back; the first device appears in the UI in < 0.5 s; a full /24 scan takes ≈ 4–6 s
- [P0] Single scan / live monitoring (configurable interval); in live mode, devices that drop off are marked offline automatically

### 3. Device identification (beyond NDI)
- [P0] Full IEEE vendor database (MA-L / MA-M / MA-S / IAB / CID), queried offline
- [P0] Detect randomized (locally administered) MACs and label them "Private address"
- [P0] Apple model identifier → marketing name (AppleDB, MIT)
- [P0] Multi-signal classification: Bonjour services/TXT (model, am, md, ty, rpMd, deviceid…), UPnP, NetBIOS, hostname rules, vendor rules, open ports → device type + model + confidence
- [P0] Device types: router, computer, laptop, phone, tablet, TV, streaming box, speaker, printer, camera, NAS, game console, smart home, IoT, watch, network device, server, virtual machine, unknown
- [P1] Users can manually override the device type

### 4. Port scanning
- [P0] Presets: common ports (about 150, hand-picked for LAN devices), well-known ports 1–1024, all 1–65535, custom (`22,80,8000-8100`)
- [P0] Non-blocking connect + kqueue for high concurrency (256 concurrent by default); scan the selected device or all devices
- [P0] Show IANA service names and descriptions for ports
- [P1] Fetch the page title from open HTTP ports and grab banners from common ports

### 5. Device library and persistence
- [P0] Keep a separate device library per network (by gateway MAC): first seen, last seen, name history
- [P0] Custom name, notes, custom URL, favorite, custom type
- [P0] Import / export custom names (soft import: keep the current value on conflict; hard import: overwrite on conflict)
- [P1] Latency history (sparkline), online status timeline

### 6. Interface (SwiftUI, macOS 26 Liquid Glass)
- [P0] Three-column layout: sidebar (network switcher + smart groups + type groups) / device list / inspector
- [P0] Table view: every LanScan column + type, model, latency, first/last seen; sortable, columns can be shown/hidden
- [P1] Card grid view (large icon, name, model, status)
- [P0] Inspector: device avatar, name editing, all addresses, hostnames, service list, ports, identification details, notes, quick actions
- [P0] Search (full text over name/IP/MAC/vendor/model/port), smart groups: All / Online / Offline / New / Favorites
- [P0] Quick actions: open in browser, SSH, SMB (Finder), Screen Sharing (VNC), Wake-on-LAN, copy IP/MAC/name/vendor
- [P0] Export: CSV (comma/semicolon), TSV, PSV, JSON, Markdown
- [P0] Settings window: Scan, Ports, Privacy (public IP lookup), Notifications, Data management
- [P0] Keyboard shortcuts: ⌘R scan, ⇧⌘R live monitoring, ⌘K clear, ⌘F search, ⌥⌘I inspector, ⌘P port scan, ⌘+/⌘- font size
- [P1] Menu bar icon: online device count, new devices, quick scan
- [P1] New device notifications (live monitoring mode)
- [P0] Option to hide IPv6-only devices; adapts to light/dark mode

### 7. Data sources (all public/open source)
| Data | Source | License |
|---|---|---|
| MAC vendors | IEEE Registration Authority (standards-oui.ieee.org) | Public |
| Port service names | IANA Service Name and Transport Protocol Port Number Registry | Public |
| Apple models | AppleDB (api.appledb.dev / littlebyteorg/appledb) | MIT |
| DNS-SD service types | The same IANA registry (service names) | Public |

`Scripts/update_data.py` generates compact TSV files from these sources, which are bundled into the app; later they can also be updated online from Settings.

### 8. Non-functional requirements
- Speed: cold launch shows the window in < 0.5 s; the vendor database loads lazily in < 100 ms; scanning never blocks the main thread, and UI refreshes are batched (≤ 10 per second)
- Native: Swift 6 + SwiftUI + a little AppKit; no third-party dependencies, no analytics/tracking SDKs
- Permissions: the first scan triggers the "Local Network" permission prompt; not sandboxed (needs to run `arp` and use raw sockets)
- Localization: English UI, with a Simplified Chinese translation (follows the system language)

## III. Implementation status (2026-10-16)

Done: every P0 item above, plus these P1 items: UPnP/SSDP, automatic switching on network change, manual device type override, card view, menu bar icon, new device notifications, latency sparklines, banner grabbing (HTTP titles, SSH and others), online vendor database updates, multiple custom IP range presets (picking one from the sidebar network menu starts a scan; an old single range is migrated automatically), device online timeline (one sample per full scan, about 30 days / 500 samples, online percentage shown in the inspector), per-device online/offline alerts, network overview (the inspector when no device is selected), the View ▸ Columns menu, recognizing the same network by subnet + shared devices and merging device libraries that had been split, and scanning other subnets across routers (reusing that subnet's device library, with reverse hostname lookups sent to the LAN router).

Not yet implemented / later iterations:
- Printing (exporting to Markdown / CSV works instead)
- An optional privileged helper: native ARP scanning over BPF and passive listening (no dependence on the system ARP table)

Verified platform facts: macOS 27 hides the ARP/NDP neighbor tables from processes that are not Developer ID signed and masks the local MAC as `02:00:00:00:00:00`. LanDetector is Developer ID signed, falls back to running `/usr/sbin/arp -anl` when sysctl is unavailable, and reads the local MAC through IOKit.

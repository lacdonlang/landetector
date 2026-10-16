import LanDetectorKit
import SwiftUI

struct MenuBarView: View {
    private let model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let online = model.devices.filter(\.isOnline).sorted { $0.sortableIP < $1.sortableIP }
        let recent = model.devices.filter { model.sessionNewIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.interface?.kind.symbol ?? "network")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.interface?.displayName ?? "无网络").font(.headline)
                    Text(model.interface?.cidr ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(online.count)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("台在线").font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.isScanning {
                ProgressView(value: model.progress)
            }

            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("新设备", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(recent.prefix(4)) { DeviceMenuRow(device: $0) }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("在线设备").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(online) { DeviceMenuRow(device: $0) }
                    }
                }
                .frame(maxHeight: 260)
            }

            Divider()
            HStack {
                Button(model.isScanning ? "停止" : "扫描", systemImage: model.isScanning ? "stop.fill" : "play.fill") {
                    model.isScanning ? model.stopScan() : model.startScan()
                }
                Button(model.isLive ? "停止监控" : "实时监控", systemImage: "dot.radiowaves.left.and.right") {
                    model.toggleLive()
                }
                Spacer()
                Button("打开", systemImage: "macwindow") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Button("退出", systemImage: "power") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct DeviceMenuRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 8) {
            DeviceIcon(kind: device.effectiveKind, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(device.displayName).font(.callout).lineLimit(1)
                Text(device.ipv4?.description ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            LatencyText(latency: device.latency).font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let ip = device.ipv4 { DeviceActions.copy(ip.description) }
        }
        .help("点击拷贝 IP 地址")
    }
}

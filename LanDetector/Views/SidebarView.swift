import LanDetectorKit
import SwiftUI

struct SidebarView: View {
    private let model = AppModel.shared

    var body: some View {
        @Bindable var model = model
        let counts = model.counts
        List(selection: $model.sidebar) {
            Section {
                NetworkCard()
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .selectionDisabled()
            }

            Section("设备") {
                row("全部设备", "square.grid.2x2", counts.all, .all)
                row("在线", "wifi", counts.online, .online)
                row("离线", "moon.zzz", counts.offline, .offline)
                row("新设备", "sparkles", counts.recent, .recent)
                row("收藏", "star", counts.favorites, .favorites)
            }

            let kinds = DeviceKind.allCases.filter { (counts.kinds[$0] ?? 0) > 0 }
            if !kinds.isEmpty {
                Section("类型") {
                    ForEach(kinds) { kind in
                        Label {
                            Text(kind.title)
                        } icon: {
                            DeviceIcon(kind: kind, size: 18)
                        }
                        .badge(counts.kinds[kind] ?? 0)
                        .tag(SidebarItem.kind(kind))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, _ symbol: String, _ count: Int, _ item: SidebarItem) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(item)
    }
}

/// Summary of the selected interface and Internet connection.
struct NetworkCard: View {
    private let model = AppModel.shared

    var body: some View {
        if let iface = model.interface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: iface.kind.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(LinearGradient(colors: [.accentColor.opacity(0.8), .accentColor], startPoint: .top,
                                                   endPoint: .bottom),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(iface.displayName).font(.headline)
                        Text("\(iface.name) · \(iface.cidr)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if model.isLive {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                            .symbolEffect(.variableColor.iterative)
                            .help("实时监控中")
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    item("网关", iface.gateway?.description)
                    item("本机 MAC", iface.mac?.description)
                    item("DNS", model.dnsServers.prefix(2).joined(separator: ", "))
                    if let pub = model.publicIP {
                        item("公网 IPv4", pub.ipv4.map { "\(pub.flag ?? "") \($0)" })
                        item("公网 IPv6", pub.ipv6)
                        item("运营商", pub.isp)
                    }
                }
                .font(.caption)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private func item(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }
}

import LanDetectorKit
import SwiftUI

struct PortScanSheet: View {
    private let model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.portPreset) private var presetRaw = PortPreset.common.rawValue
    @AppStorage(Prefs.customPorts) private var customPorts = ""
    @State private var started = false

    private var preset: PortPreset { PortPreset(rawValue: presetRaw) ?? .common }

    /// Selected devices, or every online device when nothing is selected.
    private var targets: [Device] {
        let selected = model.selectedDevices.filter { $0.ipv4 != nil }
        return selected.isEmpty ? model.devices.filter { $0.isOnline && $0.ipv4 != nil } : selected
    }

    var body: some View {
        let targets = self.targets
        let portCount = preset.ports(custom: customPorts).count
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Port Scan").font(.title2.weight(.semibold))
                    Text(targets.count == 1 ? "\(targets[0].displayName) · \(targets[0].ipv4?.description ?? "")"
                                            : String(localized: "\(targets.count) devices"))
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                Picker("Ports to scan", selection: $presetRaw) {
                    ForEach(PortPreset.allCases) { p in
                        Text(p.title).tag(p.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                if preset == .custom {
                    TextField("Ports", text: $customPorts, prompt: Text("e.g. 22,80,443,8000-8100"))
                }
                LabeledContent("Estimate") {
                    Text(verbatim: String(localized: "\(portCount * targets.count) connections") + " · "
                         + estimate(portCount * targets.count))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(model.portScanRunning)

            if started || model.portScanRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.portScanProgress)
                    Text(model.portScanStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !model.portScanRunning {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(targets) { d in
                                let fresh = model.device(d.id) ?? d
                                HStack(alignment: .firstTextBaseline) {
                                    Text(fresh.displayName).fontWeight(.medium)
                                    Spacer()
                                    Text(fresh.openPorts.isEmpty ? String(localized: "No open ports")
                                                                 : fresh.openPorts.map { PortDatabase.shared.label(for: $0) }.joined(separator: ", "))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }

            HStack {
                Spacer()
                if model.portScanRunning {
                    Button("Stop") { model.cancelPortScan() }
                } else {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(started ? String(localized: "Scan Again") : String(localized: "Start Scan")) {
                        started = true
                        model.scanPorts(targets.map(\.id), preset: preset, custom: customPorts)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(targets.isEmpty || portCount == 0)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func estimate(_ connections: Int) -> String {
        let seconds = Double(connections) / 640 * 0.5
        if seconds < 2 { return String(localized: "about 1 second") }
        if seconds < 90 { return String(localized: "about \(Int(seconds)) seconds") }
        return String(localized: "about \(Int(seconds / 60)) minutes")
    }
}

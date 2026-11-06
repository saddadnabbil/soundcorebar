import SwiftUI

@main
struct SoundcoreBarApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            Image(systemName: model.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.deviceName).font(.headline)
                Spacer()
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }

            if let s = model.state {
                HStack(spacing: 16) {
                    battery("L", s.batteryL, s.chargingL)
                    battery("R", s.batteryR, s.chargingR)
                }
                controls(s.sound).disabled(!model.canWrite)
                Divider()
                dualConnection(s).disabled(!model.canWrite)
                Text("Firmware \(s.firmwareL) / \(s.firmwareR)")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(placeholder).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let n = model.note {
                Text(n).font(.caption).foregroundStyle(.orange)
            }

            Divider()
            HStack {
                Button("Refresh") { model.refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 310)
    }

    @ViewBuilder
    private func controls(_ sm: SoundModes) -> some View {
        Picker("Mode", selection: bind(sm.ambient) { $0.ambient = $1 }) {
            Text("ANC").tag(Ambient.noiseCanceling.rawValue)
            Text("Transparency").tag(Ambient.transparency.rawValue)
            Text("Normal").tag(Ambient.normal.rawValue)
        }
        .pickerStyle(.segmented).labelsHidden()

        if sm.ambient == Ambient.noiseCanceling.rawValue {
            section("Noise cancelling") {
                Picker("ANC type", selection: bind(sm.ncMode) { $0.ncMode = $1 }) {
                    Text("Manual").tag(NCMode.manual.rawValue)
                    Text("Adaptive").tag(NCMode.adaptive.rawValue)
                    Text("Scene").tag(NCMode.multiScene.rawValue)
                }
                .pickerStyle(.segmented).labelsHidden()

                switch NCMode(rawValue: sm.ncMode) {
                case .manual:
                    Picker("Strength", selection: bind(sm.manual) { $0.manual = $1 }) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag(UInt8($0)) }
                    }
                    .pickerStyle(.segmented)
                case .adaptive:
                    Text("Adaptive level: \(sm.adaptive)/5").font(.caption).foregroundStyle(.secondary)
                case .multiScene:
                    Picker("Scene", selection: bind(sm.scene) { $0.scene = $1 }) {
                        Text("Transport").tag(ANCScene.transport.rawValue)
                        Text("Outdoor").tag(ANCScene.outdoor.rawValue)
                        Text("Indoor").tag(ANCScene.indoor.rawValue)
                    }
                    .pickerStyle(.segmented)
                case nil:
                    Text("Unknown ANC type \(sm.ncMode)").font(.caption)
                }
            }
        }

        if sm.ambient != Ambient.normal.rawValue {
            Toggle("Wind noise reduction", isOn: Binding(
                get: { sm.windSuppression },
                set: { on in model.setSound { $0.wind = on ? ($0.wind | 1) : ($0.wind & ~1) } }
            ))
        }
    }

    @ViewBuilder
    private func dualConnection(_ s: DeviceState) -> some View {
        Toggle("Dual connection", isOn: Binding(get: { s.multipoint }, set: { model.setMultipoint($0) }))
        if s.multipoint {
            if let devices = model.dualDevices {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(devices) { d in dualRow(d) }
                }
            } else {
                Text("Loading devices…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Only one device can be connected at a time.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func dualRow(_ d: DualDevice) -> some View {
        let thisMac = model.isThisMac(d)
        return HStack(spacing: 8) {
            Image(systemName: thisMac ? "laptopcomputer" : "iphone")
                .frame(width: 18).foregroundStyle(d.connected ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.name.isEmpty ? d.address : d.name).lineLimit(1)
                Text(thisMac ? "This Mac" : d.connected ? "Connected" : "Not connected")
                    .font(.caption2).foregroundStyle(d.connected ? .green : .secondary)
            }
            Spacer()
            if !thisMac {
                Button(d.connected ? "Disconnect" : "Connect") { model.setConnected(d, !d.connected) }
                    .controlSize(.small)
                    .disabled(model.dualBusy || (!d.connected && model.connectedDualCount >= 2))
            }
        }
    }

    private func bind(_ value: UInt8, _ apply: @escaping (inout SoundModes, UInt8) -> Void) -> Binding<UInt8> {
        Binding(get: { value }, set: { v in model.setSound { apply(&$0, v) } })
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func battery(_ side: String, _ level: UInt8, _ charging: Bool) -> some View {
        let pct = Int(min(level, 10)) * 10
        let sym = pct >= 88 ? "battery.100percent" : pct >= 63 ? "battery.75percent"
            : pct >= 38 ? "battery.50percent" : pct >= 13 ? "battery.25percent" : "battery.0percent"
        return HStack(spacing: 4) {
            Text(side).font(.caption.bold())
            Image(systemName: sym)
            Text("\(pct)%").monospacedDigit()
            if charging { Image(systemName: "bolt.fill").foregroundStyle(.yellow) }
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .orange
        default: return .gray
        }
    }

    private var statusText: String {
        switch model.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        case .notPaired: return "Not paired"
        case .failed: return "Error"
        }
    }

    private var placeholder: String {
        switch model.status {
        case .notPaired: return "No paired Soundcore device with the vendor control service was found."
        case .disconnected: return "Earbuds are not connected to this Mac."
        case .failed(let m): return "\(m). If the Soundcore phone app is open, close it and press Refresh."
        default: return "Reading state…"
        }
    }
}

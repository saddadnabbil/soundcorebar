import AppKit
import Foundation
import IOBluetooth

final class Model: ObservableObject {
    @Published private(set) var status: LinkStatus = .connecting
    @Published private(set) var state: DeviceState?
    @Published private(set) var note: String?
    /// Devices the earbuds remember for dual connection (nil until the first 0b 01 list arrives).
    @Published private(set) var dualDevices: [DualDevice]?
    /// True from a connect/disconnect command until the next device list (or a timeout).
    @Published private(set) var dualBusy = false
    private var dualPending: [DualDevice] = []
    private var dualNextPage: UInt8 = 1
    private var dualBusyTimeout: DispatchWorkItem?
    /// This Mac's Bluetooth address, used to label it and to never offer "Disconnect" for it.
    private let hostAddress = IOBluetoothHostController.default()?.addressAsString()?
        .replacingOccurrences(of: "-", with: ":").uppercased()
    /// Incremented on every full state read from the device (lets tests tell fresh reads from optimistic updates).
    private(set) var stateReads = 0
    /// Incremented on every 06 01 sound-mode notification pushed by the device.
    private(set) var soundPushes = 0

    let link = SoundcoreLink()
    private var refreshWork: DispatchWorkItem?
    private var refreshDeadline: DispatchTime?

    init() {
        link.onStatus = { [weak self] s in
            guard let self else { return }
            if s != self.status { Log.write("status: \(s)") }
            self.status = s
            if s != .connected { self.state = nil; self.dualDevices = nil; self.setDualBusy(false) }
        }
        link.onFrame = { [weak self] f in self?.handle(f) }
        link.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.link.stop() }
    }

    var deviceName: String { link.deviceName ?? "soundcore" }
    var canWrite: Bool { status == .connected && state?.isA3959 == true }

    var iconName: String {
        guard status == .connected, let s = state else { return "headphones.slash" }
        switch Ambient(rawValue: s.sound.ambient) {
        case .noiseCanceling: return "earbuds"
        case .transparency: return "ear.badge.waveform"
        default: return "ear"
        }
    }

    func refresh() {
        if status == .connected { link.send(SCQ.encode(SCQ.requestState)) } else { link.tryOpen() }
    }

    func setSound(_ mutate: (inout SoundModes) -> Void) {
        guard canWrite, var sm = state?.sound else { return }
        mutate(&sm)
        guard sm != state?.sound else { return }
        if link.send(SCQ.encode(SCQ.setSoundModes, sm.bytes)) {
            state?.sound = sm  // optimistic; confirmed by the 06 01 notification
            note = nil
        } else {
            note = "Write failed"
        }
    }

    // MARK: Dual connection

    func isThisMac(_ d: DualDevice) -> Bool { d.address == hostAddress }
    var connectedDualCount: Int { dualDevices?.filter(\.connected).count ?? 0 }

    func setMultipoint(_ on: Bool) {
        guard canWrite, state?.multipoint != on else { return }
        if link.send(SCQ.encode(SCQ.setDualEnabled, [on ? 1 : 0])) {
            state?.multipoint = on  // optimistic; confirmed by the follow-up state read
            Log.write("dual connection -> \(on)")
            note = nil
            scheduleRefresh(after: 1.5)
        } else {
            note = "Write failed"
        }
    }

    func setConnected(_ d: DualDevice, _ connect: Bool) {
        guard canWrite, !dualBusy, state?.multipoint == true, !isThisMac(d) else { return }
        if connect && connectedDualCount >= 2 { note = "Disconnect a device first (max 2)"; return }
        if link.send(SCQ.encode(connect ? SCQ.dualConnect : SCQ.dualDisconnect, d.rawAddress)) {
            Log.write("dual \(connect ? "connect" : "disconnect") \(d.address) \(d.name)")
            note = nil
            setDualBusy(true)
            // Connecting takes a few seconds; re-read twice so the list settles.
            scheduleRefresh(after: 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.requestDualDevices() }
        } else {
            note = "Write failed"
        }
    }

    private func setDualBusy(_ busy: Bool) {
        dualBusyTimeout?.cancel()
        dualBusyTimeout = nil
        dualBusy = busy
        guard busy else { return }
        let w = DispatchWorkItem { [weak self] in self?.dualBusy = false }
        dualBusyTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
    }

    private func requestDualDevices() {
        guard status == .connected, state?.multipoint == true else { return }
        link.send(SCQ.encode(SCQ.dualDevices))
    }

    /// Collects a multi-frame 0b 01 list. Pages must arrive in order 1...total; anything else
    /// (a lost page, or two overlapping responses) discards the partial list.
    private func takeDualPage(_ page: DualDevicesPage) {
        if page.index == 1 {
            dualPending = []
        } else if page.index != dualNextPage {
            dualPending = []; dualNextPage = 1
            Log.write("0b 01 page \(page.index)/\(page.total) out of order, dropped")
            return
        }
        dualPending += page.devices
        dualNextPage = page.index &+ 1
        guard page.index >= page.total else { return }
        var seen = Set<[UInt8]>()
        let list = dualPending.filter { seen.insert($0.rawAddress).inserted }
        dualPending = []; dualNextPage = 1
        dualDevices = list
        setDualBusy(false)
        Log.write("dual devices: " + list.map { "\($0.name)[\($0.connected ? "on" : "off")]" }.joined(separator: ", "))
    }

    private func handle(_ f: Frame) {
        switch f.cmd {
        case SCQ.stateResponse where !f.body.isEmpty:
            if let s = DeviceState.parse(f.body) {
                state = s
                stateReads += 1
                Log.write("state: fw \(s.firmwareL)/\(s.firmwareR) battery L\(s.batteryL) R\(s.batteryR) sound "
                          + s.sound.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
                note = s.isA3959 ? nil : "Not an A3959; controls disabled"
                if s.multipoint { requestDualDevices() } else { dualDevices = nil }
            } else {
                note = "Unrecognised state layout (\(f.body.count) bytes); controls disabled"
            }
        case SCQ.soundModesUpdate:
            if let sm = SoundModes(f.body) {
                state?.sound = sm; soundPushes += 1
                Log.write("push 06 01: " + sm.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
            }
        case SCQ.dualDevices where !f.body.isEmpty:
            if let page = DualDevicesPage.parse(f.body) {
                takeDualPage(page)
            } else {
                Log.write("unparsed 0b 01 (\(f.body.count) bytes)")
            }
        case 0x0102, 0x0103, 0x0104:  // TWS / battery / charging pushes: re-read full state
            scheduleRefresh()
        default:
            break  // ACKs (empty-body echo) and unknown pushes
        }
    }

    /// Coalesces refresh requests into one read. A request for a later time pushes the pending
    /// read back, so a write's settle delay is never cut short by an earlier push-triggered read.
    private func scheduleRefresh(after delay: Double = 0.5) {
        let deadline = DispatchTime.now() + delay
        if let pending = refreshDeadline, pending >= deadline { return }
        refreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.refreshWork = nil
            self?.refreshDeadline = nil
            self?.refresh()
        }
        refreshWork = w
        refreshDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: w)
    }
}

import Foundation
import IOBluetooth

enum LinkStatus: Equatable {
    case notPaired, disconnected, connecting, connected
    case failed(String)
}

/// Owns the RFCOMM control channel. All IOBluetooth callbacks arrive on the main run loop.
final class SoundcoreLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var onFrame: ((Frame) -> Void)?
    var onStatus: ((LinkStatus) -> Void)?
    private(set) var deviceName: String?

    private var channel: IOBluetoothRFCOMMChannel?
    private var opening = false
    private var reader = FrameReader()
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNote: IOBluetoothUserNotification?
    private var retryTimer: Timer?

    // Vendor UUID 0cf12d31-fac3-4553-bd80-d6832e7xxxxx (low 20 bits vary per model).
    private static let vendorPrefix: [UInt8] = [0x0c, 0xf1, 0x2d, 0x31, 0xfa, 0xc3, 0x45, 0x53, 0xbd, 0x80, 0xd6, 0x83, 0x2e]

    func start() {
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceConnected(_:fromDevice:)))
        retryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tryOpen() }
        tryOpen()
    }

    func stop() {
        retryTimer?.invalidate()
        connectNote?.unregister()
        disconnectNote?.unregister()
        channel?.close()
        channel = nil
    }

    /// Queues a frame without blocking the main (UI) thread. The buffer must stay valid until
    /// IOBluetooth reports completion, so it is heap-allocated and freed in rfcommChannelWriteComplete.
    /// Returns false if the channel is closed or the write could not be queued.
    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        guard let c = channel, !bytes.isEmpty, bytes.count <= Int(c.getMTU()) else { return false }
        let p = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
        bytes.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        let r = c.writeAsync(p, length: UInt16(bytes.count), refcon: p)
        if r != kIOReturnSuccess { p.deallocate() }
        return r == kIOReturnSuccess
    }

    func tryOpen() {
        guard channel == nil, !opening else { return }
        guard let (dev, ch) = Self.findTarget() else { onStatus?(.notPaired); return }
        deviceName = dev.name
        guard dev.isConnected() else { onStatus?(.disconnected); return }
        opening = true
        onStatus?(.connecting)
        disconnectNote?.unregister()
        disconnectNote = dev.register(forDisconnectNotification: self,
                                      selector: #selector(deviceDisconnected(_:fromDevice:)))
        var c: IOBluetoothRFCOMMChannel?
        let r = dev.openRFCOMMChannelAsync(&c, withChannelID: ch, delegate: self)
        if r != kIOReturnSuccess {
            opening = false
            onStatus?(.failed(String(format: "RFCOMM open failed (0x%08X)", r)))
        }
    }

    private static func findTarget() -> (IOBluetoothDevice, BluetoothRFCOMMChannelID)? {
        for case let d as IOBluetoothDevice in (IOBluetoothDevice.pairedDevices() ?? []) {
            if let ch = vendorChannel(d) { return (d, ch) }
        }
        return nil
    }

    private static func vendorChannel(_ d: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        for case let rec as IOBluetoothSDPServiceRecord in (d.services ?? []) {
            guard let attr = rec.getAttributeDataElement(0x0001) else { continue }
            // ServiceClassIDList is normally a sequence of UUIDs, but the JieLi stack on the
            // R50i NC publishes a bare UUID (type 3). Accept both.
            let elements: [IOBluetoothSDPDataElement] = attr.getTypeDescriptor() == 3
                ? [attr] : (attr.getArrayValue() as? [IOBluetoothSDPDataElement] ?? [])
            for el in elements {
                guard let u = el.getUUIDValue(), u.length == 16 else { continue }
                let b = [UInt8](Data(referencing: u))
                guard Array(b[0..<13]) == vendorPrefix, b[13] & 0xF0 == 0x70 else { continue }
                var ch: BluetoothRFCOMMChannelID = 0
                if rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess { return ch }
            }
        }
        return nil
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, fromDevice dev: IOBluetoothDevice) {
        guard Self.vendorChannel(dev) != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.tryOpen() }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, fromDevice dev: IOBluetoothDevice) {
        channel = nil
        opening = false
        onStatus?(.disconnected)
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ c: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        opening = false
        guard error == kIOReturnSuccess, let c else {
            c?.close()
            onStatus?(.failed(String(format: "Control channel unavailable (0x%08X)", error)))
            return
        }
        channel = c
        reader = FrameReader()
        onStatus?(.connected)
        send(SCQ.encode(SCQ.requestState))
    }

    func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length n: Int) {
        let bytes = [UInt8](UnsafeRawBufferPointer(start: p, count: n))
        for f in reader.feed(bytes) { onFrame?(f) }
    }

    func rfcommChannelWriteComplete(_ c: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!,
                                    status error: IOReturn) {
        refcon?.deallocate()
        if error != kIOReturnSuccess { Log.write(String(format: "write failed (0x%08X)", error)) }
    }

    func rfcommChannelClosed(_ c: IOBluetoothRFCOMMChannel!) {
        channel = nil
        opening = false
        onStatus?(.disconnected)
    }
}

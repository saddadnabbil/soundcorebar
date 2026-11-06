import Foundation

/// Soundcore control framing (verified on this unit in E1/E5):
/// dir[5] | cmd[2] | total_len u16 LE | body | sum8
enum SCQ {
    static let outHeader: [UInt8] = [0x08, 0xEE, 0x00, 0x00, 0x00]
    static let inHeader: [UInt8] = [0x09, 0xFF, 0x00, 0x00, 0x01]

    static let requestState: UInt16 = 0x0101
    static let stateResponse: UInt16 = 0x0101
    static let setSoundModes: UInt16 = 0x0681
    static let soundModesUpdate: UInt16 = 0x0601

    // Dual connection (multipoint). 0b 01 read verified on this unit (E7); setters per OpenSCQ30.
    static let dualDevices: UInt16 = 0x0b01      // → request / ← device list (may span several frames)
    static let setDualEnabled: UInt16 = 0x0b84   // body: [0/1]
    static let dualDisconnect: UInt16 = 0x0b81   // body: 6-byte address as sent by the device
    static let dualConnect: UInt16 = 0x0b82      // body: 6-byte address as sent by the device

    static func encode(_ cmd: UInt16, _ body: [UInt8] = []) -> [UInt8] {
        let total = outHeader.count + 2 + 2 + body.count + 1
        var f = outHeader
        f += [UInt8(cmd >> 8), UInt8(cmd & 0xFF), UInt8(total & 0xFF), UInt8(total >> 8)]
        f += body
        f.append(f.reduce(UInt8(0), &+))
        return f
    }
}

struct Frame {
    let cmd: UInt16
    let body: [UInt8]
}

/// Reassembles inbound frames from an RFCOMM byte stream (frames may be split or coalesced).
struct FrameReader {
    private var buf: [UInt8] = []

    mutating func feed(_ data: [UInt8]) -> [Frame] {
        buf += data
        var out: [Frame] = []
        while true {
            guard let start = headerIndex() else {
                if buf.count > 4 { buf.removeFirst(buf.count - 4) }
                break
            }
            if start > 0 { buf.removeFirst(start) }
            guard buf.count >= 9 else { break }
            let len = Int(buf[7]) | (Int(buf[8]) << 8)
            guard (10...4096).contains(len) else { buf.removeFirst(1); continue }
            guard buf.count >= len else { break }
            let f = Array(buf[0..<len])
            // Bad checksum: probably a false header match, so skip one byte and resync
            // instead of throwing away frames that may follow inside the claimed length.
            guard f.dropLast().reduce(UInt8(0), &+) == f[len - 1] else { buf.removeFirst(1); continue }
            buf.removeFirst(len)
            out.append(Frame(cmd: UInt16(f[5]) << 8 | UInt16(f[6]), body: Array(f[9..<(len - 1)])))
        }
        return out
    }

    private func headerIndex() -> Int? {
        guard buf.count >= 5 else { return nil }
        for i in 0...(buf.count - 5) where Array(buf[i..<(i + 5)]) == SCQ.inHeader { return i }
        return nil
    }
}

enum Ambient: UInt8, CaseIterable { case noiseCanceling = 0, transparency = 1, normal = 2 }
enum NCMode: UInt8, CaseIterable { case manual = 0, adaptive = 1, multiScene = 2 }
enum ANCScene: UInt8, CaseIterable { case transport = 0, outdoor = 1, indoor = 2 }

/// A3959 7-byte sound-mode block (state offset 64, body of 06 81 / 06 01).
/// Byte 2 is always written as the ambient mode: that is what OpenSCQ30 sends and what the
/// device accepted in E5, even though the 01 01 state reads it back as 00.
struct SoundModes: Equatable {
    var ambient: UInt8
    var manual: UInt8      // high nibble of byte 1, 1...5
    var adaptive: UInt8    // low nibble of byte 1, read-only
    var ncMode: UInt8
    var wind: UInt8        // bit0 suppression, bit1 detected (read-only)
    var sensitivity: UInt8
    var scene: UInt8

    init?(_ b: [UInt8]) {
        guard b.count == 7 else { return nil }
        ambient = b[0]; manual = b[1] >> 4; adaptive = b[1] & 0x0F
        ncMode = b[3]; wind = b[4]; sensitivity = b[5]; scene = b[6]
    }

    var bytes: [UInt8] { [ambient, (manual << 4) | (adaptive & 0x0F), ambient, ncMode, wind, sensitivity, scene] }
    var windSuppression: Bool { wind & 1 != 0 }
}

/// One entry of the 0b 01 device list: [len=0x28, connected, addr[6] (little-endian), name[32, NUL-padded]].
struct DualDevice: Equatable, Identifiable {
    let rawAddress: [UInt8]   // byte order as sent by the earbuds; echoed back unchanged in 0b 81/82
    var connected: Bool
    var name: String

    var id: [UInt8] { rawAddress }
    /// Usual display form, e.g. 11:22:33:44:55:66 (the device sends it byte-reversed).
    var address: String { rawAddress.reversed().map { String(format: "%02X", $0) }.joined(separator: ":") }
}

/// One frame of the 0b 01 response: [total, index (1-based), entries...].
struct DualDevicesPage: Equatable {
    let total: UInt8
    let index: UInt8
    let devices: [DualDevice]

    static func parse(_ b: [UInt8]) -> DualDevicesPage? {
        guard b.count >= 2 else { return nil }
        var devices: [DualDevice] = []
        var i = 2
        while i < b.count {
            let len = Int(b[i])
            guard len >= 8, i + 8 <= b.count else { return nil }
            let end = min(i + len, b.count)  // last entry may be padded short
            let nameBytes = b[(i + 8)..<end].prefix { $0 != 0 }
            devices.append(DualDevice(rawAddress: Array(b[(i + 2)..<(i + 8)]), connected: b[i + 1] == 1,
                                      name: String(decoding: nameBytes, as: UTF8.self)))
            i += len
        }
        return DualDevicesPage(total: b[0], index: b[1], devices: devices)
    }
}

struct DeviceState: Equatable {
    var batteryL: UInt8, batteryR: UInt8
    var chargingL: Bool, chargingR: Bool
    var firmwareL: String, firmwareR: String
    var serial: String
    var sound: SoundModes
    var multipoint: Bool      // state offset 73

    /// Parses the 91-byte A3959 state body. Returns nil for any other layout.
    static func parse(_ b: [UInt8]) -> DeviceState? {
        guard b.count == 91, let sm = SoundModes(Array(b[64..<71])) else { return nil }
        func ascii(_ r: Range<Int>) -> String { String(bytes: b[r], encoding: .ascii) ?? "?" }
        return DeviceState(batteryL: b[2], batteryR: b[3], chargingL: b[4] == 1, chargingR: b[5] == 1,
                           firmwareL: ascii(6..<11), firmwareR: ascii(11..<16), serial: ascii(16..<32), sound: sm,
                           multipoint: b[73] == 1)
    }

    /// Writes are only enabled for a unit identified as an A3959 by its serial prefix.
    var isA3959: Bool { serial.hasPrefix("3959") }
}

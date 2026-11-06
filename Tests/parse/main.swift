// Offline parser tests. No Bluetooth needed. Build/run: Tests/run_parse.sh
// The frames have the same layout as real R50i NC (A3959, firmware 01.65) replies, with the
// device names, addresses and serial replaced by dummy values.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "PASS" : "FAIL", name, detail)
    if !ok { failures += 1 }
}
func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

// 0b 01 device list: page 1/1, "my-mac" (11:22:33:44:55:66) and "My Phone" (AA:BB:CC:DD:EE:01), both connected.
let dualRX = hex("09 ff 00 00 01 0b 01 5c 00 01 01 28 01 66 55 44 33 22 11 6d 79 2d 6d 61 63 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 28 01 01 ee dd cc bb aa 4d 79 20 50 68 6f 6e 65 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 4b")
// 01 01 state, serial 3959A1B2C3D4E5F6, multipoint on.
let stateRX = hex("09 ff 00 00 01 01 01 65 00 00 01 06 07 ff ff 30 31 2e 36 35 30 31 2e 36 35 33 39 35 39 41 31 42 32 43 33 44 34 45 35 46 36 00 00 ff ff ff ff ff ff ff ff ff ff 00 00 00 00 00 00 00 00 00 00 0a ff ff 63 66 ff ff 44 44 33 00 55 00 00 01 ff 02 31 01 01 00 01 02 01 00 00 00 00 00 00 00 00 00 00 00 00 00 22")

// Frames split across reads and coalesced must still come out whole.
var reader = FrameReader()
var frames = reader.feed(Array(dualRX[0..<40]))
frames += reader.feed(Array(dualRX[40...]) + stateRX)
check("reader: two frames", frames.count == 2, "\(frames.map { String(format: "%04x", $0.cmd) })")

// A bad checksum must cost only the broken frame's header byte, not the frames after it.
var corrupt = dualRX
corrupt[corrupt.count - 1] ^= 0xFF
var reader2 = FrameReader()
let afterCorrupt = reader2.feed(corrupt + stateRX)
check("reader: resync after bad checksum", afterCorrupt.map(\.cmd) == [SCQ.stateResponse])

let dual = frames.first { $0.cmd == SCQ.dualDevices }.flatMap { DualDevicesPage.parse($0.body) }
check("0b 01 page 1/1", dual?.total == 1 && dual?.index == 1)
check("0b 01 two devices", dual?.devices.count == 2)
if let d = dual?.devices, d.count == 2 {
    check("device 1", d[0].name == "my-mac" && d[0].address == "11:22:33:44:55:66" && d[0].connected,
          "\(d[0].name) \(d[0].address)")
    check("device 2", d[1].name == "My Phone" && d[1].address == "AA:BB:CC:DD:EE:01" && d[1].connected,
          "\(d[1].name) \(d[1].address)")
    check("raw address kept for echo", d[0].rawAddress == [0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
}

let state = frames.first { $0.cmd == SCQ.stateResponse }.flatMap { DeviceState.parse($0.body) }
check("state parses", state != nil)
check("state: A3959 serial", state?.isA3959 == true)
check("state: multipoint on", state?.multipoint == true)
check("state: firmware", state?.firmwareL == "01.65" && state?.firmwareR == "01.65")

// Short trailing entry (padded less than its length byte says) must not be dropped.
let short = DualDevicesPage.parse([2, 2, 0x28, 0, 1, 2, 3, 4, 5, 6] + Array("Tab".utf8) + [0, 0])
check("short trailing entry", short?.devices.first?.name == "Tab" && short?.devices.first?.connected == false)
check("garbage rejected", DualDevicesPage.parse([1, 1, 3, 0]) == nil)

// Outbound frames are well formed.
check("encode 0b 01", SCQ.encode(SCQ.dualDevices) == hex("08 ee 00 00 00 0b 01 0a 00 0c"))
let on = SCQ.encode(SCQ.setDualEnabled, [1])
check("encode 0b 84 on", on.count == 11 && on[5] == 0x0b && on[6] == 0x84 && on[7] == 11 && on[9] == 1
      && on.dropLast().reduce(UInt8(0), &+) == on.last!)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

// End-to-end test against the real earbuds, using the app's own Protocol/Link/Model sources.
// Every change is verified by a fresh 01 01 read from the device, and the original settings are
// restored at the end (also on failure). Build/run: Tests/run_e2e.sh
import Foundation

let model = Model()
var failures = 0

func spin(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if done() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return done()
}

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "PASS" : "FAIL", name, detail)
    if !ok { failures += 1 }
}

func freshRead() -> DeviceState? {
    let n = model.stateReads
    model.refresh()
    return spin(5, until: { model.stateReads > n }) ? model.state : nil
}

func describe(_ s: SoundModes) -> String { s.bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

/// Applies a change through the same path the UI uses, then checks the device ACK/push and a fresh read.
func step(_ name: String, _ mutate: (inout SoundModes) -> Void, expect: (SoundModes) -> Bool) {
    let pushes = model.soundPushes
    model.setSound(mutate)
    let pushed = spin(3, until: { model.soundPushes > pushes })
    check("\(name): device pushed 06 01", pushed)
    guard let s = freshRead() else { check("\(name): fresh state read", false); return }
    check("\(name): device state", expect(s.sound), describe(s.sound))
    _ = spin(1.5)  // let the user hear it / let the DSP settle
}

// 1. Discovery and connection
check("discovery + RFCOMM open", spin(15, until: { model.status == .connected }), "\(model.status)")
check("initial state read", spin(5, until: { model.state != nil }))
guard let initial = model.state else { print("ABORT"); exit(1) }
print("device: \(model.deviceName), fw \(initial.firmwareL)/\(initial.firmwareR), serial \(initial.serial), battery L\(initial.batteryL) R\(initial.batteryR)")
print("initial sound modes: \(describe(initial.sound))")
check("A3959 identified (writes enabled)", model.canWrite)
let original = initial.sound

// 2. Write paths
step("Transparency", { $0.ambient = Ambient.transparency.rawValue }) { $0.ambient == Ambient.transparency.rawValue }
step("Normal", { $0.ambient = Ambient.normal.rawValue }) { $0.ambient == Ambient.normal.rawValue }
step("ANC", { $0.ambient = Ambient.noiseCanceling.rawValue }) { $0.ambient == Ambient.noiseCanceling.rawValue }
step("ANC manual strength 3", { $0.ncMode = NCMode.manual.rawValue; $0.manual = 3 }) { $0.ncMode == 0 && $0.manual == 3 }
step("ANC scene Indoor", { $0.ncMode = NCMode.multiScene.rawValue; $0.scene = ANCScene.indoor.rawValue }) {
    $0.ncMode == NCMode.multiScene.rawValue && $0.scene == ANCScene.indoor.rawValue
}
step("ANC adaptive", { $0.ncMode = NCMode.adaptive.rawValue }) { $0.ncMode == NCMode.adaptive.rawValue }
step("Wind reduction toggled", { $0.wind ^= 1 }) { ($0.wind & 1) != (original.wind & 1) }

// 3. Restore
step("Restore original", { $0 = original }) { $0.bytes == original.bytes }
if let final = freshRead() {
    check("final state equals initial (all fields)", final.sound == original, describe(final.sound))
}

model.link.stop()
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

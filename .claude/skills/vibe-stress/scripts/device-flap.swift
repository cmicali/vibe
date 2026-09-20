// CoreAudio helper for device-flap.py. One flap per invocation, so the driver
// owns pacing, counting and every oracle.
//
// `vanish` is the faithful stimulus: it builds a PUBLIC aggregate over a real
// output device, makes it the system default, then destroys it — so the default
// device genuinely ceases to exist, which is what a USB DAC does when it sleeps.
// `move` only reassigns the default between two devices that both persist; it
// is a strictly weaker stimulus, kept because it separates "the default moved"
// from "the device vanished".
//
// `rotate` cycles the default across a list of REAL devices in one long-lived
// process. It creates nothing, so it cannot degrade coreaudiod the way vanish
// can, and it measures what a bind actually costs per interface — which varies
// by 6x and NOT in the direction anyone guesses (see the table in SKILL.md).
//
// TRAP: this changes the SYSTEM default output, so it moves audio for every app
// on the machine, not just Vibe. It restores the original default on every exit
// path including SIGINT/SIGTERM, and destroys its aggregate before exiting —
// but a SIGKILL leaves both behind. That is why device changes are excluded
// from the unattended stress profiles and live here instead.
import CoreAudio
import Foundation

func readDefault() -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var id: AudioDeviceID = 0
    var sz = UInt32(4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &id)
    return id
}

@discardableResult
func setDefault(_ id: AudioDeviceID) -> Bool {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var v = id
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
                                      0, nil, UInt32(4), &v) == noErr
}

func uid(_ id: AudioDeviceID) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var s: CFString = "" as CFString
    var sz = UInt32(MemoryLayout<CFString>.size)
    let r = withUnsafeMutablePointer(to: &s) { AudioObjectGetPropertyData(id, &a, 0, nil, &sz, $0) }
    return r == noErr ? (s as String) : nil
}

// Report as one JSON line: the driver asserts on fields, never on prose.
func emit(_ d: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: d)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    emit(["ok": false, "error": "usage: device-flap <vanish|move|rotate> "
            + "<deviceA|steps> <holdMillis> [deviceB|comma,separated,devices]"])
    exit(64)
}
let mode = args[1]
guard let devA = AudioDeviceID(args[2]), let goneMs = Double(args[3]) else {
    emit(["ok": false, "error": "bad arguments"]); exit(64)
}

let original = readDefault()
var liveAggregate: AudioObjectID = 0
func cleanup() {
    if liveAggregate != 0 { AudioHardwareDestroyAggregateDevice(liveAggregate); liveAggregate = 0 }
    if readDefault() != original { setDefault(original) }
}
signal(SIGINT)  { _ in cleanup(); exit(130) }
signal(SIGTERM) { _ in cleanup(); exit(143) }
atexit { cleanup() }

switch mode {
case "move":
    guard args.count >= 5, let devB = AudioDeviceID(args[4]) else {
        emit(["ok": false, "error": "move needs deviceB"]); exit(64)
    }
    let target = (readDefault() == devA) ? devB : devA
    let ok = setDefault(target)
    Thread.sleep(forTimeInterval: goneMs / 1000.0)
    emit(["ok": ok, "mode": "move", "target": target, "defaultAfter": readDefault()])

// Rotate the system default across REAL devices, one long-lived process so the
// original default is restored once at the end rather than bounced back after
// every step. Creates and destroys nothing, so unlike vanish it cannot degrade
// coreaudiod — and it exercises each device's real bind cost, which differs by
// an order of magnitude between interfaces (measured: built-in 26ms, FiiO and
// Audient ~55ms, RME Fireface 223ms to engine start).
case "rotate":
    guard args.count >= 5 else {
        emit(["ok": false, "error": "rotate needs a comma-separated device list"]); exit(64)
    }
    let devices = args[4].split(separator: ",").compactMap { AudioDeviceID($0) }
    guard devices.count >= 2 else {
        emit(["ok": false, "error": "rotate needs at least two devices"]); exit(64)
    }
    // devA carries the iteration count in this mode.
    let steps = Int(devA)
    for i in 0..<steps {
        let target = devices[i % devices.count]
        let ok = setDefault(target)
        Thread.sleep(forTimeInterval: goneMs / 1000.0)
        emit(["ok": ok, "mode": "rotate", "step": i + 1, "target": target,
              "defaultAfter": readDefault()])
    }

case "vanish":
    guard let wrapUID = uid(devA) else {
        emit(["ok": false, "error": "cannot read UID of \(devA)"]); exit(1)
    }
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "VibeDeviceFlap",
        kAudioAggregateDeviceUIDKey: "com.vibe.deviceflap.\(getpid()).\(Int(Date().timeIntervalSince1970 * 1000))",
        kAudioAggregateDeviceIsPrivateKey: 0,          // public: the whole system sees it appear
        kAudioAggregateDeviceIsStackedKey: 0,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: wrapUID]],
        kAudioAggregateDeviceMainSubDeviceKey: wrapUID,
    ]
    var aggID: AudioObjectID = 0
    guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID) == noErr, aggID != 0 else {
        emit(["ok": false, "error": "create failed"]); exit(1)
    }
    liveAggregate = aggID
    Thread.sleep(forTimeInterval: 0.4)                  // let it enumerate
    let became = setDefault(aggID)
    Thread.sleep(forTimeInterval: 1.2)                  // let the app bind to it
    let wasDefault = readDefault() == aggID
    let destroyed = AudioHardwareDestroyAggregateDevice(aggID) == noErr   // it VANISHES
    liveAggregate = 0
    Thread.sleep(forTimeInterval: goneMs / 1000.0)
    emit(["ok": became && wasDefault && destroyed, "mode": "vanish", "aggregate": aggID,
          "becameDefault": wasDefault, "destroyed": destroyed, "defaultAfter": readDefault()])

default:
    emit(["ok": false, "error": "unknown mode \(mode)"]); exit(64)
}
cleanup()

// CoreAudio helper for device-flap.py and bitperfect-soak.py. One action per
// invocation, so the driver owns pacing, counting and every oracle.
//
// `vanish` is the faithful stimulus: a PUBLIC aggregate over a real output
// device becomes the system default and is destroyed, as a sleeping USB DAC
// disappears. `move` only reassigns the default between two persistent devices,
// separating "the default moved" from "the device vanished". `rotate` cycles the
// default across real devices, creating nothing, to measure per-interface bind
// cost (the table in SKILL.md).
//
// TRAP: this changes the SYSTEM default output, moving audio for every app. It
// restores the default and destroys its aggregate on every exit path including
// SIGINT/SIGTERM; a SIGKILL leaves both behind. Hence device changes are not a
// stress profile.
import AudioToolbox
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
    emit(["ok": false, "error": "usage: device-flap <vanish|move|rotate|rate|rates|volume> "
            + "<deviceA|steps> <holdMillis> [deviceB|comma,separated,devices|key:scalar,...]"])
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

// One long-lived process, so the original default is restored once at the end
// rather than after every step. Creates nothing, so unlike vanish it cannot
// degrade coreaudiod.
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

// devA's current nominal rate, read from the HAL: the app's own report of what
// it restored is the thing under test.
case "rate":
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var sz = UInt32(MemoryLayout<Float64>.size)
    let st = AudioObjectGetPropertyData(devA, &addr, 0, nil, &sz, &rate)
    emit(["ok": st == noErr, "mode": "rate", "device": devA, "rate": rate])

// devA's supported rates, so a correct rateUnsupported (the FiiO DAC-E10 lacks
// 88.2 kHz) is told apart from a failed switch.
case "rates":
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(devA, &addr, 0, nil, &sz) == noErr, sz > 0 else {
        emit(["ok": false, "mode": "rates", "device": devA, "error": "unreadable"]); exit(1)
    }
    var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
                                   count: Int(sz) / MemoryLayout<AudioValueRange>.size)
    let st = AudioObjectGetPropertyData(devA, &addr, 0, nil, &sz, &ranges)
    emit(["ok": st == noErr, "mode": "rates", "device": devA,
          "ranges": ranges.map { ["min": $0.mMinimum, "max": $0.mMaximum] }])

// Read or set devA's output volume scalars, so a bit-perfect run can hold a DAC
// at unity (below it the app truthfully reports volumeScaled) and restore it.
// args[4], when present, is "key:scalar,…", a key being an element number or
// "v" for the virtual main volume. Replies with every settable key's value.
case "volume":
    var writes: [String: Float32] = [:]
    if args.count >= 5 {
        for pair in args[4].split(separator: ",") {
            let kv = pair.split(separator: ":")
            if kv.count == 2, let v = Float32(kv[1]) { writes[String(kv[0])] = v }
        }
    }
    var values: [String: Float32] = [:]
    var ok = true
    var keyed = (0...64).map { element in
        ("\(element)", AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: UInt32(element)))
    }
    keyed.append(("v", AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                  mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)))
    for (key, address) in keyed {
        var addr = address
        guard AudioObjectHasProperty(devA, &addr) else { continue }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(devA, &addr, &settable) == noErr, settable.boolValue else { continue }
        if var v = writes[key] {
            ok = ok && AudioObjectSetPropertyData(devA, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
        }
        var v: Float32 = 0
        var sz = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(devA, &addr, 0, nil, &sz, &v) == noErr { values[key] = v }
    }
    emit(["ok": ok, "mode": "volume", "device": devA, "elements": values])

default:
    emit(["ok": false, "error": "unknown mode \(mode)"]); exit(64)
}
cleanup()

#!/usr/bin/env swift
// Full-file PCM oracle. Start capture before playback; only the first 50 ms
// (the measured player-volume settling interval) is excluded. The marker must
// be non-silent and nonperiodic; use generate-test-audio.sh --render-tests.
//
// <file> <seconds> [device] [--set-rate] [--force-volume] [--play-app <binary>]
// --self-test exercises the SAME comparator without any device or permission.
// --compare <reference> <capture> checks saved captures without hardware.
// --acceptance <fixture-directory> [device] --play-app <binary>
//   [--force-volume] [--switch-device <other-device>] [--require-driver-fixtures]
// runs the transport/toggle/restore matrix and quits/relaunches the app.
// --blackhole-check uses the same arguments for only the driver/lifecycle cases.
// --next-file <file> compares a same-format gapless join, including its seam.
// --reference <wav> compares a lossless codec against its original PCM.
// --idle-resume-at <seconds> captures a paused seek after the six-second idle stop.
// --ordinary checks the dormant normal chain and reports its sample changes.
// --device-check <file> <device> --play-app <binary> [--require-exclusive]
// checks the live mode's negotiation, idle release and format restoration.
// Hardware runs require an idle Debug app already routed to the named device.

import AudioToolbox
import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Synchronization
import Darwin

// exit() skips Swift defers. Register each acquired resource before the next
// operation can fail, and use the same cleanup for errors and normal exit.
var cleanupActions: [() -> Void] = []
var cleanupErrors: [String] = []
var cleaning = false
var lastPlayerState: [String: Any] = [:]
let interrupted = Atomic<Int32>(0)
for number in [SIGINT, SIGTERM, SIGHUP] {
    signal(number) { interrupted.store($0, ordering: .relaxed) }
}
@discardableResult func cleanup() -> Bool {
    cleaning = true
    while let action = cleanupActions.popLast() { action() }
    cleaning = false
    return cleanupErrors.isEmpty
}
func fail(_ message: String) -> Never {
    let failedState = lastPlayerState
    cleanup()
    report(["exact": false, "error": message, "cleanupErrors": cleanupErrors, "playerAtFailure": failedState])
    exit(interrupted.load(ordering: .relaxed) == 0 ? 1 : 128 + interrupted.load(ordering: .relaxed))
}
func pause(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        if !cleaning && interrupted.load(ordering: .relaxed) != 0 { fail("interrupted") }
        // NSWorkspace's process list updates through the main run loop.
        let interval = min(0.02, max(0, end.timeIntervalSinceNow))
        if !RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval)) {
            Thread.sleep(forTimeInterval: interval)
        }
    } while Date() < end
}

func compare(_ reference: [[Float]], _ capture: [[Float]], skip: Int, allowSilentChannels: Bool = false) -> [String: Any] {
    guard skip >= 0, !reference.isEmpty, reference.count <= capture.count,
          (reference.count == capture.count || allowSilentChannels),
          let length = reference.first?.count, skip <= length, length - skip >= 64,
          reference.allSatisfy({ $0.count == length && $0.allSatisfy(\.isFinite) }),
          let captured = capture.first?.count, capture.allSatisfy({ $0.count == captured }),
          captured >= length - skip else { return ["exact": false, "reason": "invalid reference, incomplete frames or channel mismatch"] }
    guard reference.contains(where: { $0[skip..<(skip + 64)].contains(where: { abs($0) > 1e-5 }) }) else {
        return ["exact": false, "reason": "silent alignment marker; use the seeded noise fixture"]
    }
    func markerMatches(_ samples: [[Float]], _ frame: Int, approximate: Bool = false) -> Bool {
        reference.indices.allSatisfy { c in
            (0..<64).allSatisfy { i in
                let expected = reference[c][skip+i], actual = samples[c][frame+i]
                return actual.isFinite && (approximate ? abs(expected-actual) <= 0.002 : expected.bitPattern == actual.bitPattern)
            }
        }
    }
    // A periodic marker can hide a whole missing/repeated period. Refuse an
    // ambiguous source or recording rather than select a convenient match.
    guard !(0...(length - 64)).contains(where: { $0 != skip && markerMatches(reference, $0) }) else {
        return ["exact": false, "reason": "repeated reference marker; use a nonperiodic fixture"]
    }
    var alignment: Int?
    for frame in 0...(captured - 64) where markerMatches(capture, frame) {
        guard alignment == nil else { return ["exact": false, "reason": "ambiguous capture marker"] }
        alignment = frame
    }
    let approximate = alignment == nil
    if approximate {
        // Diagnostic only: never fit away gain, resampling or a changed bit.
        alignment = (0...(captured - 64)).first { markerMatches(capture, $0, approximate: true) }
    }
    guard let start = alignment, length - skip <= captured - start else {
        return ["exact": false, "reason": "missing marker or truncated capture"]
    }
    var mismatches = 0, first = -1
    var peak: Float = 0
    for c in reference.indices {
        for f in skip..<length {
            let value = capture[c][start+f-skip]
            if !value.isFinite || value.bitPattern != reference[c][f].bitPattern {
                first = first < 0 ? f : min(first, f)
                mismatches += 1
                peak = value.isFinite ? max(peak, abs(value-reference[c][f])) : .infinity
            }
        }
    }
    let end = start + length - skip
    let unexpected = capture.prefix(reference.count).reduce(0) { total, channel in
        total + channel[..<max(0, start-skip)].filter { $0 != 0 }.count
              + channel[end...].filter { $0 != 0 }.count
    } + capture.dropFirst(reference.count).reduce(0) { $0 + $1.filter { $0 != 0 }.count }
    return ["exact": !approximate && mismatches == 0 && unexpected == 0, "comparedFrames": length-skip,
            "channels": reference.count, "captureChannels": capture.count,
            "mismatchedSamples": mismatches, "unexpectedSamples": unexpected,
            "firstBadFrame": first, "maxAbsError": peak.isFinite ? Double(peak) : -1,
            "captureStartFrame": start, "sourceStartFrame": skip, "approximateAlignment": approximate]
}
func referenceFitsFloat32(_ format: AudioStreamBasicDescription) -> Bool {
    if format.mFormatID == kAudioFormatLinearPCM {
        return format.mBitsPerChannel <= ((format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? 32 : 24)
    }
    return !([kAudioFormatAppleLossless, kAudioFormatFLAC].contains(format.mFormatID)
             && format.mFormatFlags == kAppleLosslessFormatFlag_32BitSourceData)
}
func readPCM(_ url: URL) -> (Double, [[Float]]) {
    do {
        let file = try AVAudioFile(forReading: url)
        guard referenceFitsFloat32(file.fileFormat.streamDescription.pointee) else {
            fail("reference precision exceeds float32; decoding would hide source bits: \(url.path)")
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var samples = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length-file.framePosition)))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { fail("premature EOF: \(url.path)") }
            for c in samples.indices { samples[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: Int(buffer.frameLength))) }
        }
        return (file.processingFormat.sampleRate, samples)
    } catch { fail("could not decode \(url.path): \(error)") }
}
func savePCM(_ url: URL, rate: Double, samples: [[Float]]) {
    guard (1...64).contains(samples.count), let frames = samples.first?.count, frames > 0,
          frames <= Int(UInt32.max), samples.allSatisfy({ $0.count == frames }),
          let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(samples.count)) else {
        fail("invalid capture shape")
    }
    // AVAudioFormat's channel-count initializer returns nil above stereo.
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
        fail("cannot allocate saved capture")
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    for c in samples.indices {
        samples[c].withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: frames) }
    }
    do {
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    } catch { fail("cannot save capture: \(error)") }
}
func report(_ result: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}
func debug(_ binary: String, _ arguments: [String], required: Bool = true) -> [String: Any] {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: binary)
    task.arguments = ["--debug-cmd"] + arguments
    task.standardOutput = pipe
    if !required { task.standardError = FileHandle.nullDevice }
    do { try task.run() } catch {
        if !required { return [:] }
        if cleaning { cleanupErrors.append("debug client: \(error)"); return [:] }
        fail("could not run debug client: \(error)")
    }
    // Drain before waiting so a large state reply cannot fill the pipe.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (json["ok"] as? Bool) != false else {
        if !required { return [:] }
        let message = "debug command failed: \(arguments): \(String(data: data, encoding: .utf8) ?? "")"
        if cleaning { cleanupErrors.append(message); return [:] }
        fail(message)
    }
    if !cleaning && interrupted.load(ordering: .relaxed) != 0 { fail("interrupted") }
    return json
}

if CommandLine.arguments.contains("--self-test") {
    var cases: [String] = []
    func expect(_ name: String, _ reference: [[Float]], _ capture: [[Float]], skip: Int = 0, allowSilentChannels: Bool = false,
                exact: Bool, frames: Int? = nil, start: Int? = nil, firstBad: Int? = nil) {
        let result = compare(reference, capture, skip: skip, allowSilentChannels: allowSilentChannels)
        guard result["exact"] as? Bool == exact,
              frames == nil || result["comparedFrames"] as? Int == frames,
              start == nil || result["captureStartFrame"] as? Int == start,
              firstBad == nil || result["firstBadFrame"] as? Int == firstBad else {
            report(result); fail("oracle self-test failed: \(name)")
        }
        cases.append(name)
    }
    var reference = [[Float]](repeating: [], count: 2)
    for c in reference.indices {
        for i in 0..<4096 {
            let integer = (i * 7919 + c * 1297) % 65521 - 32760
            reference[c].append(Float(integer) / 131072)
        }
    }
    let delayed = reference.map { [Float](repeating: 0, count: 137) + $0 + [Float](repeating: 0, count: 256) }
    expect("delayed identity", reference, delayed, exact: true, frames: 4096, start: 137)
    expect("no padding", reference, reference, exact: true, frames: 4096, start: 0)
    expect("mono", [reference[0]], [delayed[0]], exact: true, frames: 4096, start: 137)
    let shortest = reference.map { Array($0.prefix(64)) }
    expect("exactly one marker", shortest, shortest, exact: true, frames: 64, start: 0)
    var faded = reference
    for c in faded.indices { for f in 0..<128 { faded[c][f] *= Float(f)/128 } }
    expect("startup excluded", reference, faded, skip: 128, exact: true, frames: 3968, start: 128)
    expect("startup included", reference, faded, exact: false)
    for name in ["drop", "duplicate", "swap", "gain", "polarity", "clip", "truncate", "silence", "nan", "infinity", "lsb", "channels", "short", "late-fade", "channel-delay", "crosstalk", "zero-block", "last-lsb", "tail-duplicate", "tail-nan", "prefix-audio", "double-play", "marker-lsb"] {
        var bad = reference
        switch name {
        case "drop": for c in bad.indices { bad[c].remove(at: 3000) }
        case "duplicate": for c in bad.indices { bad[c].insert(bad[c][3000], at: 3000) }
        case "swap": bad.swapAt(0, 1)
        case "gain": bad = bad.map { $0.map { $0 * 0.999 } }
        case "polarity": bad = bad.map { $0.map { -$0 } }
        case "clip": bad = bad.map { $0.map { min(0.1, max(-0.1, $0)) } }
        case "truncate": bad = bad.map { Array($0.dropLast()) }
        case "silence": bad = bad.map { $0.map { _ in 0 } }
        case "nan": bad[1][3000] = .nan
        case "infinity": bad[1][3000] = .infinity
        case "late-fade": bad[0][128] *= 0.5
        case "lsb": bad[1][3000] += 1 / 8388608
        case "channels": bad.removeLast()
        case "channel-delay": bad[1].insert(0, at: 0); bad[1].removeLast()
        case "crosstalk": bad[1][3000] += bad[0][3000] / 1000
        case "zero-block": for c in bad.indices { bad[c].replaceSubrange(2048..<2112, with: repeatElement(0, count: 64)) }
        case "last-lsb": bad[1][4095] += 1 / 8388608
        case "tail-duplicate": bad = bad.map { $0 + [$0.last!] }
        case "tail-nan": bad = bad.map { $0 + [.nan] }
        case "prefix-audio": bad = bad.map { [0.25] + $0 }
        case "double-play": bad = bad.map { $0 + $0 }
        case "marker-lsb": bad[1][63] += 1 / 8388608
        default: bad = bad.map { Array($0.prefix(128)) }
        }
        // Padding makes missing frames fail sample comparison too, not only
        // the length gate. No corruption is hidden by a tolerance or realign.
        bad = bad.map { $0 + [Float](repeating: 0, count: 4096) }
        expect(name, reference, bad, exact: false)
    }
    expect("empty", [], [], exact: false)
    expect("empty channel", [[]], [[]], exact: false)
    expect("negative exclusion", reference, reference, skip: -1, exact: false)
    expect("overflowing exclusion", reference, reference, skip: Int.max, exact: false)
    expect("excludes all", reference, reference, skip: 4096, exact: false)
    expect("ragged reference", [reference[0], []], reference, exact: false)
    expect("ragged capture", reference, [reference[0], []], exact: false)
    expect("too short", reference, reference.map { Array($0.dropLast()) }, exact: false)
    expect("silent marker", [[Float](repeating: 0, count: 4096)], [[Float](repeating: 0, count: 4096)], exact: false)
    let periodic = reference.map { Array(repeating: Array($0.prefix(32)), count: 128).flatMap { $0 } }
    expect("periodic source", periodic, periodic, exact: false)
    var invalid = reference; invalid[1][3000] = .nan
    expect("invalid reference", invalid, invalid, exact: false)
    var boundary = reference; boundary[0][128] += 1 / 8388608
    expect("first included LSB", reference, boundary, skip: 128, exact: false, firstBad: 128)
    var limits = reference
    let extremes: [Float] = [-1, Float(1).nextDown, 0, -0.0, 1 / 8388608, -1 / 8388608, .leastNormalMagnitude, .leastNonzeroMagnitude]
    limits[1].replaceSubrange(3000..<(3000+extremes.count), with: extremes)
    expect("sample extremes", limits, limits, exact: true, frames: 4096)
    var zeroChanged = limits; zeroChanged[1][3003] = 0
    expect("signed zero changed", limits, zeroChanged, exact: false, firstBad: 3003)
    let surround = limits.map { $0 + [Float](repeating: 0, count: 256) }
    expect("silence after EOF", limits, surround, exact: true, frames: 4096)
    var wide = reference + reference.map { $0.map { $0 / 2 } }
    expect("four channels", wide, wide, exact: true, frames: 4096)
    let wider = wide + wide.map { $0.map { $0 / 2 } }
    expect("eight channels", wider, wider, exact: true, frames: 4096)
    let padded = delayed + [[Float]](repeating: [Float](repeating: 0, count: delayed[0].count), count: 14)
    expect("stereo on sixteen channels", reference, padded, allowSilentChannels: true, exact: true, frames: 4096)
    let savedCapture = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-oracle-\(UUID().uuidString).caf")
    cleanupActions.append { try? FileManager.default.removeItem(at: savedCapture) }
    savePCM(savedCapture, rate: 48000, samples: padded)
    let (savedRate, savedSamples) = readPCM(savedCapture)
    guard savedRate == 48000, savedSamples.count == 16 else { fail("saved capture lost its format") }
    expect("saved sixteen-channel PCM", reference, savedSamples, allowSilentChannels: true, exact: true, frames: 4096)
    cleanup()
    expect("extra channels require explicit routing", reference, padded, exact: false)
    for (frame, value) in [(0, Float(0.1)), (150, Float.nan), (padded[0].count-1, Float.leastNonzeroMagnitude)] {
        var bad = padded; bad[15][frame] = value
        expect("unused channel must remain silent \(frame)", reference, bad, allowSilentChannels: true, exact: false)
    }
    wide[3][4095] += 1 / 8388608
    expect("last wider channel", reference + reference.map { $0.map { $0 / 2 } }, wide, exact: false, firstBad: 4095)
    let joined = reference.map { $0 + $0.map { $0 / 2 } }
    expect("gapless seam", joined, joined, exact: true, frames: 8192)
    for offset in [-1, 0, 1] {
        var damaged = joined; damaged[1][4096+offset] += 1 / 8388608
        expect("gapless seam LSB \(offset)", joined, damaged, exact: false, firstBad: 4096+offset)
    }
    for (codec, bits, flags, fits) in [
        (kAudioFormatLinearPCM, UInt32(16), UInt32(0), true),
        (kAudioFormatLinearPCM, 24, 0, true), (kAudioFormatLinearPCM, 32, 0, false),
        (kAudioFormatLinearPCM, 32, kAudioFormatFlagIsFloat, true),
        (kAudioFormatLinearPCM, 64, kAudioFormatFlagIsFloat, false),
        (kAudioFormatAppleLossless, 0, kAppleLosslessFormatFlag_24BitSourceData, true),
        (kAudioFormatAppleLossless, 0, kAppleLosslessFormatFlag_32BitSourceData, false),
        (kAudioFormatFLAC, 0, kAppleLosslessFormatFlag_24BitSourceData, true),
        (kAudioFormatFLAC, 0, kAppleLosslessFormatFlag_32BitSourceData, false)] {
        var format = AudioStreamBasicDescription()
        format.mFormatID = codec; format.mBitsPerChannel = bits; format.mFormatFlags = flags
        guard referenceFitsFloat32(format) == fits else { fail("reference precision gate failed") }
        cases.append("reference precision \(codec)/\(bits)/\(flags)")
    }
    report(["selfTest": true, "cases": cases.count, "passedCases": cases]); exit(0)
}
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--compare" {
    let (rate, reference) = readPCM(URL(fileURLWithPath: CommandLine.arguments[2]))
    let (captureRate, capture) = readPCM(URL(fileURLWithPath: CommandLine.arguments[3]))
    guard rate == captureRate else { fail("capture rate differs from reference") }
    let result = compare(reference, capture, skip: Int(rate * 0.05), allowSilentChannels: true)
    report(result); exit(result["exact"] as? Bool == true ? 0 : 1)
}
var arguments = Array(CommandLine.arguments.dropFirst())
let acceptance = arguments.contains("--acceptance")
let blackholeCheck = arguments.contains("--blackhole-check")
let requireDriverFixtures = arguments.contains("--require-driver-fixtures")
let deviceCheck = arguments.contains("--device-check")
let ordinary = arguments.contains("--ordinary")
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name) else { return nil }
    guard i+1 < arguments.count, !arguments[i+1].hasPrefix("--") else { fail("\(name) needs a value") }
    let value = arguments[i+1]
    arguments.removeSubrange(i...i+1)
    return value
}
let alternateDevice = option("--switch-device") ?? (requireDriverFixtures && acceptance ? "VibeBlackHoleBare 16ch" : nil)
let capturePath = option("--save-capture")
let nextFile = option("--next-file").map { URL(fileURLWithPath: $0).standardizedFileURL.path }
let referenceFile = option("--reference")
var resumePosition: Double?
if let raw = option("--idle-resume-at") {
    guard let value = Double(raw), value.isFinite, value >= 0 else {
        fail("--idle-resume-at needs a finite, nonnegative position")
    }
    resumePosition = value
}
let requireExclusive = arguments.contains("--require-exclusive")
let appBinary = option("--play-app").map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
arguments.removeAll { ["--device-check", "--require-exclusive", "--acceptance", "--blackhole-check", "--ordinary", "--require-driver-fixtures"].contains($0) }
if deviceCheck || acceptance || blackholeCheck { arguments.insert("8", at: min(1, arguments.count)) }
let forceVolume = arguments.contains("--force-volume")
// --set-rate: put the device at the file's rate ourselves and back at exit —
// for measuring the everyday chain with the mode OFF, when Vibe does not.
let setRate = arguments.contains("--set-rate")
arguments.removeAll { $0 == "--force-volume" || $0 == "--set-rate" }
guard (2...3).contains(arguments.count), let seconds = Double(arguments[1]), seconds.isFinite, seconds > 0, seconds <= 120 else {
    fail("usage: verifier <file> <seconds> [device] [--play-app binary] [--force-volume] [--set-rate] [--next-file file] [--ordinary]; or --acceptance/--blackhole-check <fixtures> [device] --play-app binary [--require-driver-fixtures]; or --device-check <file> [device] --play-app binary [--require-exclusive]; or --self-test / --compare reference capture")
}
let fileURL = URL(fileURLWithPath: arguments[0])
let deviceName = arguments.count >= 3 ? arguments[2] : "BlackHole 2ch"

// MARK: - HAL helpers

func property(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
    var address = property(selector), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size % 4 == 0 else { return nil }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr, Int(size) == ids.count * 4 else { return nil }
    return ids
}
func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = property(selector), value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}
func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = property(selector), value: UInt32 = 0, size: UInt32 = 4
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && size == 4 ? value : nil
}
func writeUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: UInt32) -> Bool {
    var address = property(selector), data = value
    return AudioObjectSetPropertyData(object, &address, 0, nil, 4, &data) == noErr
}
// The fixture driver exposes CFNumbers through documented custom properties.
func driverNumber(_ device: AudioDeviceID, _ selector: UInt32) -> UInt32? {
    var address = property(selector), value: Unmanaged<CFNumber>?
    var size = UInt32(MemoryLayout<Unmanaged<CFNumber>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
          let number = value?.takeRetainedValue(), size == MemoryLayout<Unmanaged<CFNumber>?>.size else { return nil }
    var result: Int32 = 0
    return CFNumberGetValue(number, .sInt32Type, &result) && result >= 0 ? UInt32(result) : nil
}
func setDriverFault(_ device: AudioDeviceID, _ mask: UInt32) -> Bool {
    var address = property(0x76627466), value = Int32(mask) // 'vbtf'
    let number = CFNumberCreate(nil, .sInt32Type, &value)!
    var reference = Unmanaged.passUnretained(number)
    return withExtendedLifetime(number) {
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: reference)), &reference) == noErr
    } && driverNumber(device, 0x76627466) == mask
}
func deviceNamed(_ name: String) -> AudioDeviceID? {
    objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)?
        .first { stringProperty($0, kAudioObjectPropertyName) == name }
}

func nominalRate(_ device: AudioDeviceID) -> Double {
    var address = property(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
    return rate
}

func hogOwner(_ device: AudioDeviceID) -> pid_t? {
    var address = property(kAudioDevicePropertyHogMode)
    var owner: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &owner) == noErr ? owner : nil
}

// Compare every output stream's physical format, including integer/float and
// packing. Nominal rate alone would miss a depth or layout restoration defect.
func physicalFormats(_ device: AudioDeviceID) -> [[Double]] {
    var address = property(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { fail("no output streams") }
    var ids = [AudioStreamID](repeating: 0, count: Int(size)/4)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else { fail("cannot read output streams") }
    return ids.map { stream in
        var address = property(kAudioStreamPropertyPhysicalFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr else { fail("cannot read physical format") }
        return [format.mSampleRate, Double(format.mFormatID), Double(format.mFormatFlags), Double(format.mBytesPerPacket),
                Double(format.mFramesPerPacket), Double(format.mBytesPerFrame), Double(format.mChannelsPerFrame), Double(format.mBitsPerChannel)]
    }
}

// A device volume, by slot: the HAL's software volume ('vmvc', the "virtual
// main" volume) and the device's own scalars (kAudioDevicePropertyVolumeScalar)
// on the main element and each output channel. Either scales the samples
// before they loop back — BlackHole applies its scalars itself — so the oracle
// holds every slot it finds at 1.0.
typealias VolumeSlot = (selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement)
let volumeSlots: [VolumeSlot] = [
    (kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyElementMain),
    (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
] + (1...64).map { (kAudioDevicePropertyVolumeScalar, AudioObjectPropertyElement($0)) }

func readVolume(_ device: AudioDeviceID, _ slot: VolumeSlot) -> Float32? {
    var address = AudioObjectPropertyAddress(mSelector: slot.selector, mScope: kAudioObjectPropertyScopeOutput, mElement: slot.element)
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var value: Float32 = 1
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        && size == MemoryLayout<Float32>.size ? value : nil
}

func writeVolume(_ device: AudioDeviceID, _ slot: VolumeSlot, _ volume: Float32) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: slot.selector, mScope: kAudioObjectPropertyScopeOutput, mElement: slot.element)
    var value = volume
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
}

func setVolumes(_ device: AudioDeviceID, _ values: [(VolumeSlot, Float32)]) -> Bool {
    // A rate change can discard an accepted volume write. Retry only after
    // its bounded readback wait, once the asynchronous HAL change has settled.
    for _ in 0..<2 {
        var written = true
        for (slot, value) in values { if !writeVolume(device, slot, value) { written = false } }
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if written && values.allSatisfy({ readVolume(device, $0.0) == $0.1 }) { return true }
            pause(0.02)
        } while Date() < deadline
    }
    return false
}

func waitFor(_ label: String, seconds: Double = 10, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if condition() { return }
        pause(0.02)
    } while Date() < deadline
    fail("timed out: \(label)")
}
func player(_ binary: String) -> [String: Any] {
    lastPlayerState = debug(binary, ["dump_state"])["player"] as? [String: Any] ?? [:]
    return lastPlayerState
}
func bitPerfect(_ binary: String) -> [String: Any] { player(binary)["bitPerfect"] as? [String: Any] ?? [:] }
func writeRate(_ device: AudioDeviceID, _ rate: Double) -> Bool {
    var address = property(kAudioDevicePropertyNominalSampleRate), value = rate
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value) == noErr
}
func requireRestored(_ device: AudioDeviceID, _ rate: Double, _ formats: [[Double]], label: String) {
    waitFor(label) { nominalRate(device) == rate && physicalFormats(device) == formats }
    report(["case": label, "originalRate": rate, "restoredRate": nominalRate(device), "physicalFormatsRestored": true])
}

func playlistPath(_ paths: [String]) -> String {
    let url = URL(fileURLWithPath: paths[0]).deletingLastPathComponent().appendingPathComponent("acceptance-\(UUID().uuidString).m3u")
    do { try (paths.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
    catch { fail("cannot write temporary playlist: \(error)") }
    cleanupActions.append { try? FileManager.default.removeItem(at: url) }
    return url.path
}
func requireOrdinary(_ binary: String) {
    let live = player(binary), facts = live["bitPerfect"] as? [String: Any] ?? [:]
    guard facts["enabled"] as? Bool == false, facts["status"] as? String == "off",
          (facts["varispeedPresent"] as? Bool == true || live["numChannels"] as? Int == 0),
          ["preparedDeviceId", "restoreOwedToDeviceId", "hoggedDeviceId"].allSatisfy({ (facts[$0] as? Int ?? 0) == -1 }),
          facts["outputLevelListenerPresent"] as? Bool == false else {
        report(facts); fail("mode off did not retain the ordinary, dormant path")
    }
    report(["case": "ordinary-path", "report": facts])
}

// MARK: - Setup

guard var device = deviceNamed(deviceName) else { fail("no output device named \(deviceName)") }
if requireDriverFixtures {
    guard acceptance || blackholeCheck, driverNumber(device, 0x76627466) == 0,
          (physicalFormats(device).first?[6] ?? 0) >= 16,
          deviceNamed("VibeBlackHoleBare 16ch") != nil, deviceNamed("VibeBlackHole48 2ch") != nil else {
        fail("install make build-test-blackhole's package and select VibeBlackHole 16ch for --require-driver-fixtures")
    }
}
if let binary = appBinary {
    let path = URL(fileURLWithPath: binary).standardizedFileURL.resolvingSymlinksInPath().path
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.commonwealthrecordings.Vibe" }
    guard apps.count == 1, apps[0].executableURL?.standardizedFileURL.resolvingSymlinksInPath().path == path else {
        fail("exactly one Vibe must be running, from --play-app's worktree")
    }
    let state = debug(binary, ["dump_state"])
    guard let player = state["player"] as? [String: Any],
          player["manualRendering"] as? Bool == false,
          player["silent"] as? Bool == false,
          player["state"] as? String == "stopped",
          (player["requestedOutputDeviceId"] as? Int ?? -1) >= 0,
          (state["settings"] as? [String: Any])?["outputDeviceName"] as? String == deviceName else {
        fail("Use an idle, unmuted hardware Debug app explicitly routed to \(deviceName)")
    }
    guard (player["pitch"] as? NSNumber)?.doubleValue == 0,
          ["lowKill", "reverbSend", "delaySend", "shortDelaySend"].allSatisfy({ player[$0] as? Bool == false }) else {
        fail("Set pitch to zero and turn every effect off before a transparency capture")
    }
    let uid = stringProperty(device, kAudioDevicePropertyDeviceUID)
    if player["outputDeviceUID"] as? String != uid {
        guard requireDriverFixtures else { fail("idle output binding drifted from the selected device; reselect it before capture") }
        // A stopped output unit can follow a system route change. Switching
        // between our two silent virtual devices forces a fresh explicit bind.
        _ = debug(binary, ["dump_menu"])
        _ = debug(binary, ["click_menu", "VibeBlackHoleBare 16ch"])
        _ = debug(binary, ["click_menu", deviceName])
        waitFor("explicit test output rebound") {
            (debug(binary, ["dump_state"])["player"] as? [String: Any])?["outputDeviceUID"] as? String == uid
        }
    }
}

// Snapshot ALL aliases before changing any: the virtual main control can
// change the channel scalars too. Saving each after a write loses the baseline.
let savedVolumes: [(VolumeSlot, Float32)] = volumeSlots.compactMap { slot in
    var address = AudioObjectPropertyAddress(mSelector: slot.selector, mScope: kAudioObjectPropertyScopeOutput, mElement: slot.element)
    guard AudioObjectHasProperty(device, &address) else { return nil }
    guard let volume = readVolume(device, slot), volume.isFinite else { fail("cannot read device volume") }
    return (slot, volume)
}
var restoreVolumes: [(VolumeSlot, Float32)] = []
cleanupActions.append {
    let restored = setVolumes(device, restoreVolumes)
    if !restored { cleanupErrors.append("volume restore readback differs") }
    report(["cleanup": "volume", "restored": restored, "slots": restoreVolumes.map { slot, original in
        ["selector": Double(slot.selector), "element": Double(slot.element), "original": Double(original),
         "readback": Double(readVolume(device, slot) ?? -1)]
    }])
}
if savedVolumes.contains(where: { $0.1 != 1 }) {
    guard forceVolume else { fail("\(deviceName)'s volume is not unity; pass --force-volume") }
    restoreVolumes = savedVolumes
    guard setVolumes(device, savedVolumes.map { ($0.0, 1) }) else { fail("volume did not reach unity") }
}

if acceptance || blackholeCheck {
    guard let binary = appBinary, bitPerfect(binary)["enabled"] as? Bool == false else {
        fail("--acceptance requires --play-app and bit-perfect initially off")
    }
    restoreVolumes = savedVolumes
    let before = nominalRate(device), formatsBefore = physicalFormats(device)
    let settings = debug(binary, ["dump_state"])["settings"] as? [String: Any] ?? [:]
    var unavailableChecks: [String] = []
    let pauseAtEnd = settings["pauseAtTrackEnd"] as? Bool ?? false
    let reopen = settings["reopenLastPlaylist"] as? Bool ?? false
    let declick = settings["declick"] as? Bool ?? true
    var appQuit = false
    func relaunch(_ grant: String? = nil) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", URL(fileURLWithPath: binary).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path]
            + (grant.map { [$0] } ?? []) + ["--args", "--no-now-playing"]
        do { try task.run(); task.waitUntilExit() }
        catch { cleanupErrors.append("could not relaunch: \(error)"); return }
        let deadline = Date().addingTimeInterval(10)
        // NSWorkspace can report a finished launch before the channel listens.
        var ready = false
        while Date() < deadline && !ready {
            ready = NSWorkspace.shared.runningApplications.contains { $0.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path == binary && $0.isFinishedLaunching }
                && !debug(binary, ["dump_state"], required: false).isEmpty
            if !ready { pause(0.05) }
        }
        guard ready else {
            cleanupErrors.append("app's debug channel did not become ready"); return
        }
        appQuit = false
    }
    cleanupActions.append {
        if appQuit { relaunch() }
        _ = debug(binary, ["hang_open", "release"])
        _ = debug(binary, ["set_fake_cloud", "0"])
        _ = debug(binary, ["quiesce"])
        _ = debug(binary, ["set_bit_perfect", "off"])
        _ = debug(binary, ["set_pause_at_track_end", pauseAtEnd ? "on" : "off"])
        _ = debug(binary, ["set_reopen_playlist", reopen ? "on" : "off"])
        _ = debug(binary, ["set_declick", declick ? "on" : "off"])
        _ = debug(binary, ["dump_menu"])
        _ = debug(binary, ["click_menu", deviceName])
        // The mode is remembered per device: a removal or a switch away keeps
        // the loopback's entry, so clear it once the loopback is the saved device.
        let uid = stringProperty(device, kAudioDevicePropertyDeviceUID)
        let boundDeadline = Date().addingTimeInterval(2)
        while player(binary)["outputDeviceUID"] as? String != uid && Date() < boundDeadline { pause(0.02) }
        _ = debug(binary, ["set_bit_perfect", "off"])
        let deadline = Date().addingTimeInterval(2)
        while nominalRate(device) != before && Date() < deadline { pause(0.02) }
        let restored = nominalRate(device) == before && physicalFormats(device) == formatsBefore
        if !restored { cleanupErrors.append("application did not restore its original device format") }
        report(["cleanup": "application", "restored": restored, "originalRate": before, "restoredRate": nominalRate(device)])
    }
    _ = debug(binary, ["set_pause_at_track_end", "off"])
    _ = debug(binary, ["set_reopen_playlist", "off"])
    // Every capture is compared sample-exact from its first frame, and with
    // declick on a bit-perfect start ramps its first 10 ms.
    _ = debug(binary, ["set_declick", "off"])
    func fixture(_ name: String) -> String { fileURL.appendingPathComponent(name).path }
    func started(_ path: String, active: Bool) {
        waitFor("settled \(path)") {
            let state = debug(binary, ["dump_state"]), live = state["player"] as? [String: Any] ?? [:]
            return (state["currentTrack"] as? [String: Any])?["url"] as? String == path
                && (live["position"] as? Double ?? 0) > 0
                && (!active || (live["bitPerfect"] as? [String: Any])?["status"] as? String == "active")
        }
    }
    func captureCase(_ label: String, _ name: String, _ extra: [String] = [], on captureDevice: String? = nil) {
        _ = debug(binary, ["quiesce"])
        report(["case": label, "phase": "capture"])
        let task = Process()
        task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let (rate, samples) = readPCM(URL(fileURLWithPath: fixture(name)))
        let duration = Double(samples[0].count) / rate + 1
        task.arguments = [fixture(name), String(extra.contains("--next-file") ? duration * 2 : duration), captureDevice ?? deviceName, "--play-app", binary,
                          "--save-capture", fileURL.deletingLastPathComponent().appendingPathComponent("capture-\(label).caf").path] + extra
        do { try task.run() } catch { fail("cannot launch capture: \(error)") }
        cleanupActions.append { if task.isRunning { task.terminate(); task.waitUntilExit() } }
        while task.isRunning { pause(0.05) }
        cleanupActions.removeLast()
        guard task.terminationStatus == 0 else { fail("acceptance capture failed: \(label)") }
    }
    let first = fixture("noise-44100-16-2.wav"), second = fixture("noise-48000-24-2.wav")
    if !blackholeCheck {
    // The ordinary varispeed can alter the alignment marker too. Assert its
    // dormant state and rendered duration; identity remains diagnostic only.
    captureCase("mode-off", "noise-44100-16-2.wav", ["--set-rate", "--ordinary"])
    _ = debug(binary, ["set_bit_perfect", "on"])
    for rate in [44100, 48000, 88200, 96000, 176400, 192000] {
        for bits in [16, 24, 32] {
            let name = "noise-\(rate)-\(bits)-2.wav"
            captureCase(name, name)
        }
    }
    for name in ["lossless.flac", "lossless.m4a", "lossless.aiff"] {
        captureCase(name, name, ["--reference", second])
    }
    for name in ["limits-16.wav", "limits-24.wav", "limits.wav", "marked-silence.wav", "marked-impulse.wav", "marked-sweep.wav"] {
        captureCase(name, name)
    }
    captureCase("paused-seek-idle-resume", "noise-48000-24-2.wav", ["--idle-resume-at", "0.5"])
    var reportCases = [("integer32-low-bits.wav", "depthInsufficient"), ("float64-low-bits.wav", "depthInsufficient"),
                       ("noise-48000-24-1.wav", "channelConversion")]
    for channels in [4, 8, 16] { reportCases.append(("noise-48000-24-\(channels).wav", "channelConversion")) }
    for name in ["lossy.m4a", "lossy.aac", "alias.mp4", "cbr.mp3", "vbr.mp3", "lossy.mp2", "lossy.qta"] {
        if FileManager.default.fileExists(atPath: fixture(name)) { reportCases.append((name, "sourceLossy")) }
        else { unavailableChecks.append("lossy report for \(name): fixture encoder unavailable") }
    }
    for (name, status) in reportCases {
        _ = debug(binary, ["quiesce"])
        _ = debug(binary, ["open", fixture(name)])
        started(fixture(name), active: false)
        waitFor("truthful \(status) report") { bitPerfect(binary)["status"] as? String == status }
        report(["case": name, "expectedStatus": status, "report": bitPerfect(binary)])
    }
    if !savedVolumes.isEmpty {
        restoreVolumes = savedVolumes
        _ = debug(binary, ["open", fixture("limits.wav")]); started(fixture("limits.wav"), active: true)
        for gain: Float32 in [0.5, 1] {
            guard setVolumes(device, savedVolumes.map { ($0.0, gain) }) else { fail("cannot set gain for report check") }
            let status = gain == 1 ? "active" : "volumeScaled"
            waitFor("volume report \(status)") { bitPerfect(binary)["status"] as? String == status }
            report(["case": "volume-report", "gain": gain, "report": bitPerfect(binary)])
        }
    }
    let balanceSlot: VolumeSlot = (kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioObjectPropertyElementMain)
    if let original = readVolume(device, balanceSlot) {
        cleanupActions.append {
            if !setVolumes(device, [(balanceSlot, original)]) { cleanupErrors.append("balance restoration failed") }
        }
        _ = debug(binary, ["open", fixture("limits.wav")]); started(fixture("limits.wav"), active: true)
        for balance: Float32 in [0.25, original] {
            guard setVolumes(device, [(balanceSlot, balance)]) else { fail("cannot change balance") }
            let status = balance == 0.5 ? "active" : "volumeScaled"
            waitFor("balance report \(status)") { bitPerfect(binary)["status"] as? String == status }
            report(["case": "balance-report", "balance": balance, "report": bitPerfect(binary)])
        }
    } else { unavailableChecks.append("live balance changes: no readable virtual balance control") }
    var muteAddress = property(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
    if AudioObjectHasProperty(device, &muteAddress) {
        var original: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &original) == noErr else { fail("cannot read mute") }
        cleanupActions.append {
            var readback: UInt32 = 0
            if AudioObjectSetPropertyData(device, &muteAddress, 0, nil, size, &original) != noErr
                || AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &readback) != noErr || readback != original {
                cleanupErrors.append("mute restoration failed")
            }
        }
        _ = debug(binary, ["open", fixture("limits.wav")]); started(fixture("limits.wav"), active: true)
        for wanted: UInt32 in [1, original] {
            var value = wanted
            guard AudioObjectSetPropertyData(device, &muteAddress, 0, nil, size, &value) == noErr else { fail("cannot change mute") }
            let status = wanted == 0 ? "active" : "muted"
            waitFor("mute report \(status)") { bitPerfect(binary)["status"] as? String == status }
            report(["case": "mute-report", "muted": wanted != 0, "report": bitPerfect(binary)])
        }
    } else { unavailableChecks.append("live mute changes: no main mute control") }
    _ = debug(binary, ["open", second]); started(second, active: true)
    _ = debug(binary, ["quiesce"])
    waitFor("stop unloads") { player(binary)["state"] as? String == "stopped" }
    captureCase("stop-replay", "noise-48000-24-2.wav")
    captureCase("gapless-same-format", "noise-48000-16-2.wav", ["--next-file", second])
    _ = debug(binary, ["open", playlistPath([first, second])])
    started(first, active: true)
    let deadline = Date().addingTimeInterval(6)
    var switched = false
    repeat {
        let state = debug(binary, ["dump_state"]), live = state["player"] as? [String: Any] ?? [:]
        if (state["currentTrack"] as? [String: Any])?["url"] as? String == second,
           (live["position"] as? Double ?? 0) > 0,
           (live["bitPerfect"] as? [String: Any])?["sampleRate"] as? Double == 48000 {
            switched = true; report(["case": "rate-switch-boundary", "player": live]); break
        }
        guard live["gaplessArmed"] as? Bool == false else { fail("a hardware rate switch armed a gapless splice") }
        pause(0.02)
    } while Date() < deadline
    guard switched, nominalRate(device) == 48000 else { fail("track boundary did not switch to 48 kHz") }
    // A hardware switch interrupts capture; prove the settled destination's
    // PCM on a fresh replay, without claiming sample continuity at that edge.
    captureCase("after-rate-switch", "noise-48000-24-2.wav")
    _ = debug(binary, ["open", first]); started(first, active: true)
    for iteration in 0..<12 {
        let enabled = iteration % 2 != 0
        let start = ProcessInfo.processInfo.systemUptime
        _ = debug(binary, ["seek", "0"])
        _ = debug(binary, ["set_bit_perfect", enabled ? "on" : "off"])
        waitFor("live mode toggle") {
            let live = player(binary), facts = live["bitPerfect"] as? [String: Any] ?? [:]
            return live["state"] as? String == "playing" && (live["position"] as? Double ?? 0) > 0
                && facts["enabled"] as? Bool == enabled && facts["varispeedPresent"] as? Bool == !enabled
                && (!enabled || facts["status"] as? String == "active")
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard elapsed < 5 else { fail("live mode toggle stalled for \(elapsed) seconds") }
        report(["case": "live-mode-toggle", "iteration": iteration, "enabled": enabled, "elapsedMs": elapsed * 1000])
    }
    for enabled in [false, true] {
        _ = debug(binary, ["quiesce"])
        _ = debug(binary, ["set_bit_perfect", enabled ? "on" : "off"])
        _ = debug(binary, ["hang_open", URL(fileURLWithPath: second).lastPathComponent])
        _ = debug(binary, ["open", second])
        waitFor("open held") {
            let state = debug(binary, ["dump_state"])
            return (state["ui"] as? [String: Any])?["displayState"] as? String == "loading"
        }
        _ = debug(binary, ["set_bit_perfect", enabled ? "off" : "on"])
        _ = debug(binary, ["hang_open", "release"])
        started(second, active: !enabled)
        if enabled { requireOrdinary(binary) }
        else { guard bitPerfect(binary)["varispeedPresent"] as? Bool == false else { fail("toggle-on open kept varispeed") } }
        report(["case": enabled ? "off-during-open" : "on-during-open", "report": bitPerfect(binary)])
    }
    _ = debug(binary, ["quiesce"])
    _ = debug(binary, ["set_bit_perfect", "off"])
    requireRestored(device, before, formatsBefore, label: "mode-off-restoration")
    // Keep an existing format obligation across an open that fails.
    _ = debug(binary, ["set_bit_perfect", "on"])
    _ = debug(binary, ["open", second]); started(second, active: true)
    _ = debug(binary, ["quiesce"])
    _ = debug(binary, ["set_fake_cloud", "0.2", "100", "uniform", "fail=\(URL(fileURLWithPath: first).lastPathComponent)"])
    _ = debug(binary, ["open", first])
    waitFor("failed open") { (debug(binary, ["dump_state"])["ui"] as? [String: Any])?["displayState"] as? String == "error" }
    _ = debug(binary, ["set_fake_cloud", "0"])
    _ = debug(binary, ["set_bit_perfect", "off"])
    requireRestored(device, before, formatsBefore, label: "failed-open-restoration")
    if let other = alternateDevice {
        guard let otherID = deviceNamed(other), otherID != device else { fail("--switch-device must name a different device") }
        _ = debug(binary, ["quiesce"])
        _ = debug(binary, ["set_bit_perfect", "on"])
        _ = debug(binary, ["open", second]); started(second, active: true)
        _ = debug(binary, ["quiesce"])
        _ = debug(binary, ["dump_menu"])
        _ = debug(binary, ["click_menu", other])
        waitFor("alternate device") { player(binary)["outputDeviceUID"] as? String == stringProperty(otherID, kAudioDevicePropertyDeviceUID) }
        requireRestored(device, before, formatsBefore, label: "device-switch-restoration")
        report(["case": "return-to-loopback", "phase": "switch"])
        // The alternate device has its own mode, off; the loopback kept its on.
        guard bitPerfect(binary)["enabled"] as? Bool == false else { fail("the alternate device inherited the loopback's mode") }
        _ = debug(binary, ["click_menu", deviceName])
        waitFor("return to loopback") { player(binary)["outputDeviceUID"] as? String == stringProperty(device, kAudioDevicePropertyDeviceUID) }
        waitFor("loopback's remembered mode") { bitPerfect(binary)["enabled"] as? Bool == true }
        _ = debug(binary, ["set_bit_perfect", "off"])
    }
    }
    if deviceName.contains("BlackHole") {
        guard let uid = stringProperty(device, kAudioDevicePropertyDeviceUID),
              let box = objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyBoxList)?
                .first(where: { objectIDs($0, kAudioBoxPropertyDeviceList)?.contains(device) == true }),
              readUInt32(box, kAudioBoxPropertyAcquired) == 1 else { fail("BlackHole's acquired box is unavailable") }
        var acquiredAddress = property(kAudioBoxPropertyAcquired), settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(box, &acquiredAddress, &settable) == noErr, settable.boolValue else {
            fail("this BlackHole build cannot simulate removal")
        }
        let deviceDefaults = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice,
                              kAudioHardwarePropertyDefaultInputDevice].filter {
            readUInt32(AudioObjectID(kAudioObjectSystemObject), $0) == device
        }
        // Removal invalidates AudioObjectIDs and deliberately retires Vibe's
        // restore obligation. Re-find by UID and restore the driver's baseline.
        func reconnectedDevice() -> AudioDeviceID? {
            objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)?
                .first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
        }
        cleanupActions.append {
            if !writeUInt32(box, kAudioBoxPropertyAcquired, 1) { cleanupErrors.append("BlackHole reacquisition failed") }
            let deadline = Date().addingTimeInterval(5)
            while reconnectedDevice() == nil && Date() < deadline { pause(0.02) }
            if let restoredDevice = reconnectedDevice() {
                device = restoredDevice
                _ = debug(binary, ["quiesce"])
                _ = debug(binary, ["set_bit_perfect", "off"])
                let settleDeadline = Date().addingTimeInterval(5)
                while Date() < settleDeadline {
                    let facts = bitPerfect(binary)
                    if facts["enabled"] as? Bool == false && facts["restoreOwedToDeviceId"] as? Int == -1 { break }
                    pause(0.02)
                }
                if !writeRate(device, before) { cleanupErrors.append("BlackHole baseline rate write failed") }
                let rateDeadline = Date().addingTimeInterval(5)
                while nominalRate(device) != before && Date() < rateDeadline { pause(0.02) }
                for selector in deviceDefaults {
                    if !writeUInt32(AudioObjectID(kAudioObjectSystemObject), selector, device) {
                        cleanupErrors.append("BlackHole system default restoration failed")
                    }
                    let defaultDeadline = Date().addingTimeInterval(2)
                    while readUInt32(AudioObjectID(kAudioObjectSystemObject), selector) != device && Date() < defaultDeadline { pause(0.02) }
                    if readUInt32(AudioObjectID(kAudioObjectSystemObject), selector) != device {
                        cleanupErrors.append("BlackHole system default readback differs")
                    }
                }
            } else { cleanupErrors.append("BlackHole did not reappear; reacquire its box in Audio MIDI Setup") }
        }
        func selectLoopback() {
            _ = debug(binary, ["quiesce"])
            _ = debug(binary, ["set_bit_perfect", "off"])
            waitFor("BlackHole in app menu") {
                _ = debug(binary, ["dump_menu"])
                return (debug(binary, ["click_menu", deviceName], required: false)["ok"] as? Bool) == true
            }
            waitFor("BlackHole bound") { player(binary)["outputDeviceUID"] as? String == uid }
            _ = debug(binary, ["set_bit_perfect", "off"]) // a removal keeps the device's remembered mode
            guard setVolumes(device, savedVolumes.map { ($0.0, 1) }) else { fail("reconnected BlackHole volume is not unity") }
        }
        if let mask = driverNumber(box, 0x76627466) {
            guard mask == 0 else { fail("test BlackHole already has an active fault lease") }
            cleanupActions.append {
                if !setDriverFault(box, 0) { cleanupErrors.append("BlackHole fault reset failed (lease expires after 60 seconds)") }
            }
            for (label, fault): (String, UInt32) in [
                ("volume-read-error", 1), ("volume-nan", 2), ("volume-wrong-size", 4),
                ("physical-format-read-error", 8), ("physical-format-write-error", 16),
                ("physical-format-write-ignored", 32), ("nominal-rate-read-error", 64), ("device-not-alive", 128)] {
                report(["case": "blackhole-\(label)", "phase": "prepare"])
                selectLoopback()
                waitFor("idle test driver before injection") { readUInt32(device, kAudioDevicePropertyDeviceIsRunning) == 0 }
                guard writeRate(device, 96000) else { fail("cannot prepare fault-test baseline") }
                waitFor("fault baseline at 96 kHz") { nominalRate(device) == 96000 }
                pause(0.25)
                guard setDriverFault(box, fault) else { fail("cannot arm driver fault \(label)") }
                pause(0.25)
                if fault == 128, readUInt32(device, kAudioDevicePropertyDeviceIsAlive) == 1,
                   driverNumber(box, 0x76627468) == 0 {
                    // HAL owns this property on AudioServerPlugIn devices and
                    // can ignore the driver's value and notification entirely.
                    guard setDriverFault(box, 0) else { fail("cannot clear ignored alive fault") }
                    unavailableChecks.append("dead-but-enumerated device: HAL returns alive without consulting the test driver; box removal is tested separately")
                    report(["case": "blackhole-\(label)", "supported": false, "injectedOperations": 0, "halAlive": 1])
                    continue
                }
                _ = debug(binary, ["set_bit_perfect", "on"])
                _ = debug(binary, ["open", fixture("silence.wav")])
                waitFor("truthful report for \(label)", seconds: 5) {
                    let state = debug(binary, ["dump_state"]), live = state["player"] as? [String: Any] ?? [:]
                    lastPlayerState = live
                    let facts = live["bitPerfect"] as? [String: Any] ?? [:]
                    let failedOpen = live["state"] as? String == "stopped"
                        && (state["ui"] as? [String: Any])?["displayState"] as? String == "error"
                    // HAL can replace a malformed scalar reply with zero before
                    // Vibe reads it. That is scaled output, never Active.
                    let sanitizedScalar = fault == 4 && facts["status"] as? String == "volumeScaled"
                        && (readVolume(device, (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain))
                            .map { $0.isFinite && $0 >= 0 && $0 < 1 } ?? false)
                    return (driverNumber(box, 0x76627468) ?? 0) > 0
                        && (facts["status"] as? String == "switchFailed" || sanitizedScalar || failedOpen
                            || (fault == 128 && live["requestedOutputDeviceId"] as? Int == -1 && facts["enabled"] as? Bool == false))
                }
                report(["case": "blackhole-\(label)", "injectedOperations": driverNumber(box, 0x76627468) ?? 0,
                        "state": debug(binary, ["dump_state"])])
                if fault != 128 {
                    _ = debug(binary, ["quiesce"])
                    waitFor("idle test driver before clearing injection") { readUInt32(device, kAudioDevicePropertyDeviceIsRunning) == 0 }
                }
                guard setDriverFault(box, 0) else { fail("cannot clear driver fault \(label)") }
                pause(0.25)
                selectLoopback()
                _ = debug(binary, ["set_bit_perfect", "on"])
                captureCase("blackhole-recovered-\(label)", "noise-48000-24-2.wav")
            }
            for fault: UInt32 in [16, 32] {
                report(["case": "blackhole-restore-refused-\(fault)", "phase": "prepare"])
                selectLoopback()
                waitFor("idle before restore-failure baseline") { readUInt32(device, kAudioDevicePropertyDeviceIsRunning) == 0 }
                guard writeRate(device, 96000) else { fail("cannot prepare restore-failure baseline") }
                waitFor("restore-failure baseline at 96 kHz") { nominalRate(device) == 96000 }
                let baselineFormats = physicalFormats(device)
                pause(0.25)
                _ = debug(binary, ["set_bit_perfect", "on"])
                _ = debug(binary, ["open", fixture("silence.wav")]); started(fixture("silence.wav"), active: true)
                guard (bitPerfect(binary)["restoreOwedToDeviceId"] as? Int ?? -1) >= 0 else { fail("format change owes no restoration") }
                _ = debug(binary, ["quiesce"])
                waitFor("idle before refusing restoration") { readUInt32(device, kAudioDevicePropertyDeviceIsRunning) == 0 }
                guard setDriverFault(box, fault) else { fail("cannot refuse restoration") }
                pause(0.25)
                _ = debug(binary, ["set_bit_perfect", "off"])
                waitFor("failed restoration retains obligation") {
                    let facts = bitPerfect(binary)
                    return facts["enabled"] as? Bool == false && facts["status"] as? String == "off"
                        && (facts["restoreOwedToDeviceId"] as? Int ?? -1) >= 0
                        && (driverNumber(box, 0x76627468) ?? 0) >= 2 && nominalRate(device) == 48000
                }
                report(["case": "blackhole-restore-refused-\(fault)", "report": bitPerfect(binary),
                        "injectedOperations": driverNumber(box, 0x76627468) ?? 0])
                guard setDriverFault(box, 0) else { fail("cannot permit restoration") }
                pause(0.25)
                _ = debug(binary, ["set_bit_perfect", "on"])
                _ = debug(binary, ["set_bit_perfect", "off"])
                requireRestored(device, 96000, baselineFormats, label: "blackhole-restore-retried-\(fault)")
                requireOrdinary(binary)
                _ = debug(binary, ["set_bit_perfect", "on"])
                captureCase("blackhole-recovered-restore-\(fault)", "noise-48000-24-2.wav")
            }
        } else {
            if requireDriverFixtures { fail("test driver's box does not expose the fault controls") }
            unavailableChecks.append("driver read/write errors, malformed controls and dead-but-enumerated device: use VibeBlackHole 16ch")
        }
        for state in ["stopped", "paused", "playing"] {
            selectLoopback()
            _ = debug(binary, ["set_bit_perfect", "on"])
            let silent = fixture("silence.wav")
            _ = debug(binary, ["open", silent]); started(silent, active: true)
            if state == "stopped" { _ = debug(binary, ["quiesce"]) }
            if state == "paused" { _ = debug(binary, ["play_pause"]) }
            waitFor("\(state) before removal") { player(binary)["state"] as? String == state }
            guard writeUInt32(box, kAudioBoxPropertyAcquired, 0) else { fail("BlackHole removal write failed") }
            waitFor("BlackHole removed") { reconnectedDevice() == nil }
            waitFor("mode off after \(state) removal") {
                let live = player(binary), facts = live["bitPerfect"] as? [String: Any] ?? [:]
                return live["requestedOutputDeviceId"] as? Int == -1 && facts["enabled"] as? Bool == false
            }
            requireOrdinary(binary)
            report(["case": "blackhole-remove-\(state)", "player": player(binary)])
            _ = debug(binary, ["quiesce"])
            guard writeUInt32(box, kAudioBoxPropertyAcquired, 1) else { fail("BlackHole replug write failed") }
            waitFor("BlackHole replugged") { reconnectedDevice() != nil }
            device = reconnectedDevice()!
            pause(0.3)
            guard player(binary)["requestedOutputDeviceId"] as? Int == -1 else { fail("replug unexpectedly undid persisted System Output fallback") }
            selectLoopback()
            _ = debug(binary, ["set_bit_perfect", "on"])
            captureCase("blackhole-replug-\(state)", "noise-48000-24-2.wav")
        }
        _ = debug(binary, ["quiesce"])
        _ = debug(binary, ["set_bit_perfect", "off"])
        let aggregateName = "Vibe BlackHole Test \(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName, kAudioAggregateDeviceUIDKey: aggregateName,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: 0]]
        ]
        var aggregate: AudioDeviceID = 0
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate) == noErr else {
            fail("cannot create temporary BlackHole aggregate")
        }
        cleanupActions.append {
            _ = debug(binary, ["quiesce"])
            _ = debug(binary, ["set_bit_perfect", "off"])
            _ = debug(binary, ["dump_menu"])
            _ = debug(binary, ["click_menu", deviceName])
            if aggregate != 0 && AudioHardwareDestroyAggregateDevice(aggregate) != noErr {
                cleanupErrors.append("temporary BlackHole aggregate removal failed")
            }
        }
        waitFor("aggregate in menu") {
            _ = debug(binary, ["dump_menu"])
            return debug(binary, ["click_menu", aggregateName], required: false)["ok"] as? Bool == true
        }
        waitFor("aggregate bound") { player(binary)["outputDeviceUID"] as? String == aggregateName }
        _ = debug(binary, ["set_bit_perfect", "on"], required: false)
        _ = debug(binary, ["open", fixture("silence.wav")]); started(fixture("silence.wav"), active: false)
        let aggregateReport = bitPerfect(binary)
        guard aggregateReport["eligibleDevice"] as? Bool == false, aggregateReport["status"] as? String == "off" else {
            report(aggregateReport); fail("aggregate incorrectly claims bit-perfect eligibility")
        }
        report(["case": "blackhole-aggregate-ineligible", "report": aggregateReport])
        _ = debug(binary, ["quiesce"])
        // Removal retains per-device preferences; retire this test-only UID
        // while it is still selected and its mode can be edited.
        _ = debug(binary, ["set_bit_perfect", "off"])
        guard AudioHardwareDestroyAggregateDevice(aggregate) == noErr else { fail("aggregate destruction failed") }
        aggregate = 0
        waitFor("aggregate removed") { deviceNamed(aggregateName) == nil && player(binary)["requestedOutputDeviceId"] as? Int == -1 }
        report(["case": "blackhole-aggregate-removal", "player": player(binary)])
        selectLoopback()
        _ = debug(binary, ["set_bit_perfect", "on"])
        _ = debug(binary, ["open", fixture("silence.wav")]); started(fixture("silence.wav"), active: true)
        var missing: [UInt32] = []
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioDevicePropertyStereoPan,
                         kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
            var address = property(selector, kAudioObjectPropertyScopeOutput)
            if !AudioObjectHasProperty(device, &address) { missing.append(selector) }
        }
        report(["case": "blackhole-absent-controls", "absentSelectors": missing, "report": bitPerfect(binary)])
        for profile in ["VibeBlackHoleBare 16ch", "VibeBlackHole48 2ch"] {
            guard let profileID = deviceNamed(profile), let profileUID = stringProperty(profileID, kAudioDevicePropertyDeviceUID) else {
                if requireDriverFixtures { fail("required driver profile disappeared: \(profile)") }
                unavailableChecks.append("driver profile \(profile): install make build-test-blackhole's package")
                continue
            }
            _ = debug(binary, ["quiesce"])
            _ = debug(binary, ["set_bit_perfect", "off"])
            let profileRate = nominalRate(profileID), profileFormats = physicalFormats(profileID)
            _ = debug(binary, ["dump_menu"])
            _ = debug(binary, ["click_menu", profile])
            waitFor("\(profile) bound") { player(binary)["outputDeviceUID"] as? String == profileUID }
            _ = debug(binary, ["set_bit_perfect", "on"])
            if profile.contains("Bare") {
                for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                 kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
                                 kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute, kAudioDevicePropertyStereoPan] {
                    for channel in 0...16 {
                        var address = property(selector, kAudioObjectPropertyScopeOutput); address.mElement = UInt32(channel)
                        guard !AudioObjectHasProperty(profileID, &address) else { fail("bare driver exposes a volume, balance, pan or mute control") }
                    }
                }
                captureCase("blackhole-no-controls", "noise-48000-24-2.wav", on: profile)
            } else {
                _ = debug(binary, ["open", first]); started(first, active: false)
                waitFor("unsupported 44.1 kHz report") { bitPerfect(binary)["status"] as? String == "rateUnsupported" }
                guard nominalRate(profileID) == 48000 else { fail("limited driver unexpectedly changed rate") }
                report(["case": "blackhole-rate-unavailable", "report": bitPerfect(binary)])
                captureCase("blackhole-supported-rate-recovery", "noise-48000-24-2.wav", on: profile)
            }
            _ = debug(binary, ["quiesce"])
            _ = debug(binary, ["set_bit_perfect", "off"])
            requireRestored(profileID, profileRate, profileFormats, label: "\(profile)-restored")
        }
        selectLoopback()
        _ = debug(binary, ["quiesce"])
        _ = debug(binary, ["set_bit_perfect", "off"])
        guard writeRate(device, before) else { fail("cannot restore BlackHole baseline after replug tests") }
        requireRestored(device, before, formatsBefore, label: "blackhole-lifecycle-baseline")
        _ = debug(binary, ["set_bit_perfect", "on"])
        _ = debug(binary, ["open", fixture("silence.wav")]); started(fixture("silence.wav"), active: true)
        guard let process = NSWorkspace.shared.runningApplications.first(where: { $0.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path == binary }) else {
            fail("cannot identify the test app for crash recovery")
        }
        let crashedPID = process.processIdentifier
        cleanupActions.append { if appQuit { relaunch() } }
        appQuit = true
        guard kill(crashedPID, SIGKILL) == 0 else { fail("cannot terminate test app for crash recovery") }
        waitFor("test app killed") { !NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == crashedPID } }
        let rateAfterCrash = nominalRate(device)
        relaunch(second)
        started(second, active: true)
        _ = debug(binary, ["quiesce"])
        _ = debug(binary, ["set_bit_perfect", "off"])
        // A killed process cannot execute its format restore. The harness owns
        // this recovery; do not credit it to the application's quit path.
        guard writeRate(device, before) else { fail("cannot restore driver baseline after app crash") }
        requireRestored(device, before, formatsBefore, label: "blackhole-crash-harness-restoration")
        report(["case": "blackhole-app-crash", "killedPID": crashedPID, "rateAfterCrash": rateAfterCrash,
                "restorationPerformedByHarness": true])
        _ = debug(binary, ["set_bit_perfect", "on"])
        captureCase("blackhole-after-app-crash", "noise-48000-24-2.wav")
    } else if blackholeCheck { fail("--blackhole-check requires a BlackHole device") }
    report(["case": "quit-restoration", "phase": "prepare"])
    _ = debug(binary, ["set_bit_perfect", "on"])
    _ = debug(binary, ["open", second]); started(second, active: true)
    appQuit = true
    _ = debug(binary, ["quit"])
    waitFor("app quit") { !NSWorkspace.shared.runningApplications.contains { $0.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path == binary } }
    requireRestored(device, before, formatsBefore, label: "quit-restoration")
    relaunch()
    let restored = cleanup()
    var notCovered = ["physical exclusive ownership and unplug", "sample continuity across hardware rate switch", "physical integer-depth negotiation", "mono-preserving hardware PCM capture", "first 50 ms after start or resume"] + unavailableChecks
    if !deviceName.contains("BlackHole") { notCovered.append("device removal, aggregate eligibility and process crash") }
    if (formatsBefore.first?[6] ?? 0) <= 2 { notCovered.append("stereo routing onto multichannel hardware: use BlackHole 16ch") }
    if alternateDevice == nil { notCovered.append("device-switch restoration: pass --switch-device") }
    if savedVolumes.isEmpty { notCovered.append("live device-volume report: no readable volume controls") }
    report(["acceptance": restored, "suite": blackholeCheck ? "blackhole-device-scenarios" : "bit-perfect-acceptance",
            "cleanupErrors": cleanupErrors, "notCovered": notCovered])
    exit(restored ? 0 : 1)
}

let (fileRate, firstSamples) = readPCM(fileURL)
var referenceSamples = firstSamples
if let path = referenceFile {
    let (rate, samples) = readPCM(URL(fileURLWithPath: path))
    guard rate == fileRate, samples.count == firstSamples.count, samples[0].count == firstSamples[0].count else {
        fail("--reference must have the same rate, channels and duration")
    }
    referenceSamples = samples
}
if let position = resumePosition {
    guard appBinary != nil, nextFile == nil, position < Double(firstSamples[0].count) / fileRate else {
        fail("--idle-resume-at requires --play-app, a position inside the file, and no --next-file")
    }
    referenceSamples = referenceSamples.map { Array($0.dropFirst(Int((position * fileRate).rounded()))) }
}
if let path = nextFile {
    let (rate, samples) = readPCM(URL(fileURLWithPath: path))
    guard rate == fileRate, samples.count == firstSamples.count else { fail("--next-file requires the same decoded format") }
    for c in samples.indices { referenceSamples[c] += samples[c] }
}

if deviceCheck {
    guard let binary = appBinary else { fail("--device-check requires --play-app") }
    let before = nominalRate(device)
    let formatsBefore = physicalFormats(device)
    let state = debug(binary, ["dump_state"])
    let player = state["player"] as! [String: Any]
    let previous = player["bitPerfect"] as? [String: Any] ?? [:]
    guard previous["enabled"] as? Bool == false else { fail("Start the device check with bit-perfect off, so restoration has an unambiguous baseline") }
    cleanupActions.append {
        _ = debug(binary, ["quiesce"])
        _ = debug(binary, ["set_bit_perfect", "off"])
        let deadline = Date().addingTimeInterval(2)
        while nominalRate(device) != before && Date() < deadline { pause(0.02) }
        if nominalRate(device) != before || physicalFormats(device) != formatsBefore {
            cleanupErrors.append("device physical format was not restored")
        }
    }
    _ = debug(binary, ["set_bit_perfect", "on"])
    _ = debug(binary, ["open", fileURL.path])
    let deadline = Date().addingTimeInterval(10)
    var facts: [String: Any] = [:]
    repeat {
        let live = debug(binary, ["dump_state"])["player"] as? [String: Any] ?? [:]
        facts = live["bitPerfect"] as? [String: Any] ?? [:]
        if facts["status"] as? String == "active" { break }
        pause(0.02)
    } while Date() < deadline
    guard facts["status"] as? String == "active", nominalRate(device) == fileRate,
          facts["rateExact"] as? Bool == true, facts["formatConfirmed"] as? Bool == true,
          facts["depthOK"] as? Bool == true, facts["channelsMatch"] as? Bool == true else {
        report(facts); fail("device did not confirm bit-perfect delivery")
    }
    if requireExclusive {
        let path = URL(fileURLWithPath: binary).standardizedFileURL.resolvingSymlinksInPath().path
        let app = NSWorkspace.shared.runningApplications.first {
            $0.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
        }
        guard facts["exclusive"] as? Bool == true, let pid = app?.processIdentifier,
              hogOwner(device) == pid else { fail("HAL did not confirm exclusive ownership by this app") }
    }
    // Quiesce exercises stop and the real six-second idle release.
    _ = debug(binary, ["quiesce"])
    pause(6.5)
    let idle = (debug(binary, ["dump_state"])["player"] as? [String: Any])?["bitPerfect"] as? [String: Any] ?? [:]
    guard (idle["hoggedDeviceId"] as? NSNumber)?.intValue == -1,
          !requireExclusive || hogOwner(device) == -1 else { fail("idle engine retained exclusive ownership") }
    guard cleanup() else { fail("device-check cleanup failed") }
    let restoreDeadline = Date().addingTimeInterval(2)
    while (nominalRate(device) != before || physicalFormats(device) != formatsBefore) && Date() < restoreDeadline {
        pause(0.02)
    }
    guard nominalRate(device) == before, physicalFormats(device) == formatsBefore else { fail("device physical format was not restored") }
    for (slot, volume) in restoreVolumes where readVolume(device, slot) != volume { fail("device volume was not restored") }
    report(["deviceCheck": true, "active": facts, "originalRate": before, "restoredRate": nominalRate(device), "physicalFormatsRestored": true])
    exit(0)
}
// MARK: - Capture

// --set-rate is for regular mode; it restores the original nominal rate.
var restoreRate: Double? = nil
cleanupActions.append {
    if let rate = restoreRate {
        if !writeRate(device, rate) { cleanupErrors.append("rate restore write failed") }
        let deadline = Date().addingTimeInterval(2)
        while nominalRate(device) != rate && Date() < deadline { pause(0.02) }
        let restored = nominalRate(device) == rate
        if !restored { cleanupErrors.append("rate restore readback differs") }
        report(["cleanup": "rate", "originalRate": rate, "restoredRate": nominalRate(device), "restored": restored])
    }
}
if let binary = appBinary {
    let initial = bitPerfect(binary)
    let enabled = initial["enabled"] as? Bool == true
    let before = nominalRate(device)
    let formatsBefore = (initial["restoreOwedToDeviceId"] as? Int) == -1 ? physicalFormats(device) : nil
    cleanupActions.append {
        _ = debug(binary, ["quiesce"])
        if enabled {
            _ = debug(binary, ["set_bit_perfect", "off"])
            if let formats = formatsBefore {
                let deadline = Date().addingTimeInterval(2)
                while nominalRate(device) != before && Date() < deadline { pause(0.02) }
                let restored = nominalRate(device) == before && physicalFormats(device) == formats
                if !restored { cleanupErrors.append("capture's application format was not restored") }
                report(["cleanup": "application-format", "restored": restored, "originalRate": before, "restoredRate": nominalRate(device)])
            }
            _ = debug(binary, ["set_bit_perfect", "on"])
        }
    }
}
// Prepare the file once before binding capture: a bit-perfect format switch
// invalidates an already-bound IOProc. The measured replay begins only AFTER
// capture starts, so the comparator still requires the complete source tail.
if let binary = appBinary {
    if bitPerfect(binary)["enabled"] as? Bool == true {
        _ = debug(binary, ["open", fileURL.path])
        waitFor("prepared bit-perfect format") {
            nominalRate(device) == fileRate && bitPerfect(binary)["status"] as? String == "active"
                && (player(binary)["position"] as? Double ?? 0) > 0
        }
        _ = debug(binary, ["quiesce"])
    }
}

if setRate && nominalRate(device) != fileRate {
    restoreRate = nominalRate(device)
    var rateAddress = property(kAudioDevicePropertyNominalSampleRate)
    var wanted = fileRate
    guard AudioObjectSetPropertyData(device, &rateAddress, 0, nil, UInt32(MemoryLayout<Float64>.size), &wanted) == noErr else {
        fail("could not set \(deviceName) to \(fileRate) Hz")
    }
}
let rateDeadline = Date().addingTimeInterval(15)
while nominalRate(device) != fileRate && Date() < rateDeadline {
    pause(0.05)
}
if nominalRate(device) != fileRate {
    fail("\(deviceName) never reached \(fileRate) Hz (it is at \(nominalRate(device)))")
}

if let position = resumePosition, let binary = appBinary {
    _ = debug(binary, ["open", fileURL.path])
    waitFor("playing before paused seek") { (player(binary)["position"] as? Double ?? 0) > 0 }
    _ = debug(binary, ["play_pause"])
    waitFor("paused before seek") { player(binary)["state"] as? String == "paused" }
    _ = debug(binary, ["seek", String(position)])
    waitFor("paused seek settled") { abs((player(binary)["position"] as? Double ?? -1) - position) < 1 / fileRate }
    pause(6.5)
    let live = player(binary)
    guard live["state"] as? String == "paused", abs((live["position"] as? Double ?? -1) - position) < 1 / fileRate else {
        fail("idle stop lost paused seek position")
    }
    report(["case": "paused-seek-idle", "position": position, "player": live])
}

// The device's input virtual format: what the IOProc's input buffers carry.
var streamsAddress = property(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
var streamsSize: UInt32 = 0
guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize >= 4 else {
    fail("\(deviceName) has no input stream to record from")
}
var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / 4)
guard AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &streamsSize, &streams) == noErr else {
    fail("could not read \(deviceName)'s input streams")
}
var virtualAddress = property(kAudioStreamPropertyVirtualFormat)
var virtualFormat = AudioStreamBasicDescription()
var virtualSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
guard AudioObjectGetPropertyData(streams[0], &virtualAddress, 0, nil, &virtualSize, &virtualFormat) == noErr else {
    fail("could not read \(deviceName)'s input format")
}
let captureRate = virtualFormat.mSampleRate
let captureChannels = Int(virtualFormat.mChannelsPerFrame)
let captureIsFloat = (virtualFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
let captureInterleaved = (virtualFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
guard captureIsFloat, virtualFormat.mFormatID == kAudioFormatLinearPCM, virtualFormat.mBitsPerChannel == 32, (1...64).contains(captureChannels),
      captureRate.isFinite, captureRate > 0, captureRate <= 384000 else {
    fail("\(deviceName)'s input virtual format is not float32: \(virtualFormat)")
}
let defaultOutputChanges = Atomic<Int>(0)
var defaultOutputAddress = property(kAudioHardwarePropertyDefaultOutputDevice)
let defaultOutputListener: AudioObjectPropertyListenerBlock = { _, _ in
    defaultOutputChanges.wrappingAdd(1, ordering: .relaxed)
}
guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress,
                                         nil, defaultOutputListener) == noErr else {
    fail("cannot observe system output changes during capture")
}
cleanupActions.append {
    if AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress,
                                              nil, defaultOutputListener) != noErr {
        cleanupErrors.append("system output listener removal failed")
    }
}
// Bound memory before starting IO. The callback never allocates or waits on
// a lock; release/acquire publishes only the fully copied prefix.
let capacity = Int(captureRate * (15 + seconds + 1))
guard capacity * captureChannels <= 64_000_000 else { fail("capture exceeds 256 MB limit") }
var procID: AudioDeviceIOProcID? = nil
let storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity * captureChannels)
storage.initialize(repeating: 0, count: capacity * captureChannels)
cleanupActions.append { if procID == nil { storage.deallocate() } }
let writtenFrames = Atomic<Int>(0)
let callbacks = Atomic<Int>(0)
let overflowed = Atomic<Bool>(false)
let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, _ in
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    callbacks.wrappingAdd(1, ordering: .relaxed)
    let start = writtenFrames.load(ordering: .relaxed)
    let frames = list.first.map { Int($0.mDataByteSize) / (4 * (captureInterleaved ? max(1, captureChannels) : 1)) } ?? 0
    guard start + frames <= capacity else { overflowed.store(true, ordering: .relaxed); return noErr }
    if captureInterleaved, let buffer = list.first, let data = buffer.mData {
        guard list.count == 1, Int(buffer.mNumberChannels) == captureChannels, Int(buffer.mDataByteSize) % (4 * captureChannels) == 0 else { overflowed.store(true, ordering: .relaxed); return noErr }
        storage.advanced(by: start*captureChannels).update(from: data.assumingMemoryBound(to: Float.self), count: frames*captureChannels)
    } else {
        guard list.count == captureChannels else { overflowed.store(true, ordering: .relaxed); return noErr }
        for c in 0..<captureChannels {
            guard let data = list[c].mData, list[c].mNumberChannels == 1, Int(list[c].mDataByteSize) == frames * 4 else { overflowed.store(true, ordering: .relaxed); return noErr }
            let samples = data.assumingMemoryBound(to: Float.self)
            for f in 0..<frames { storage[(start+f)*captureChannels+c] = samples[f] }
        }
    }
    writtenFrames.store(start+frames, ordering: .releasing)
    return noErr
}
guard AudioDeviceCreateIOProcID(device, ioProc, nil, &procID) == noErr, let proc = procID else {
    fail("could not create an IOProc on \(deviceName)")
}
let stopCapture = {
    if let activeProc = procID {
        if AudioDeviceStop(device, activeProc) != noErr { cleanupErrors.append("capture stop failed") }
        if AudioDeviceDestroyIOProcID(device, activeProc) == noErr { procID = nil }
        else { cleanupErrors.append("IOProc removal failed; retaining capture memory until exit") }
    }
}
cleanupActions.append(stopCapture)
guard AudioDeviceStart(device, proc) == noErr else { fail("could not start IO on \(deviceName)") }

FileHandle.standardError.write(Data("Capture ready on \(deviceName)\n".utf8))
if let binary = appBinary {
    let path = nextFile.map { playlistPath([fileURL.path, $0]) } ?? fileURL.path
    _ = debug(binary, resumePosition == nil ? ["open", path] : ["play_pause"])
    waitFor("audio advancing") { (player(binary)["position"] as? Double ?? 0) > (resumePosition ?? 0) }
    guard player(binary)["outputDeviceUID"] as? String == stringProperty(device, kAudioDevicePropertyDeviceUID) else {
        fail("playing app is bound to a different output device")
    }
    if ordinary { requireOrdinary(binary) }
    else { guard bitPerfect(binary)["status"] as? String == "active" else { fail("bit-perfect report is not active") } }
    if nextFile != nil {
        waitFor("same-format gapless armed", seconds: 1) { player(binary)["gaplessArmed"] as? Bool == true }
        report(["case": "same-format-armed", "report": bitPerfect(binary)])
    }
}

// Wait for audio, then record for `seconds` from the first non-silent frame.
let deadline = Date().addingTimeInterval(15)
var audioSeen = false
while Date() < deadline {
    pause(0.05)
    let count = writtenFrames.load(ordering: .acquiring)
    let heard = UnsafeBufferPointer(start: storage, count: count*captureChannels).contains { abs($0) > 1e-6 }
    if heard { audioSeen = true; break }
}
if !audioSeen {
    stopCapture()
    let frames = writtenFrames.load(ordering: .acquiring)
    // Frames with a zero peak means the device delivered silence — on macOS
    // that is what a process without microphone permission hears from ANY
    // input, a virtual loopback included. No frames at all means IO never ran.
    fail("no audio arrived on \(deviceName) within 15 s (\(callbacks.load(ordering: .relaxed)) callbacks, \(frames) frames)")
}
pause(seconds)
stopCapture()

// MARK: - Compare
let capturedFrames = writtenFrames.load(ordering: .acquiring)
guard !overflowed.load(ordering: .relaxed), captureRate == fileRate else { fail("capture overflow, layout change or rate mismatch") }
var captured = [[Float]](repeating: [Float](repeating: 0, count: capturedFrames), count: captureChannels)
for c in 0..<captureChannels { for f in 0..<capturedFrames { captured[c][f] = storage[f*captureChannels+c] } }
if let path = capturePath {
    savePCM(URL(fileURLWithPath: path), rate: captureRate, samples: captured)
}
var result = compare(referenceSamples, captured, skip: Int(fileRate*0.05), allowSilentChannels: true)
let audibleFrames = (0..<capturedFrames).reduce(0) { count, f in
    count + (captured.contains { abs($0[f]) > 1e-6 } ? 1 : 0)
}
result["audibleFrames"] = audibleFrames
if let path = capturePath { result["captureFile"] = path }
if let path = referenceFile { result["referenceFile"] = path }
if let position = resumePosition { result["resumedAt"] = position }
result["device"] = deviceName
result["captureRate"] = captureRate
result["fileRate"] = fileRate
result["capturedFrames"] = capturedFrames
result["defaultOutputChangeEvents"] = defaultOutputChanges.load(ordering: .relaxed)
result["forcedVolumeSlots"] = restoreVolumes.count
let passed = ordinary
    ? audibleFrames >= referenceSamples[0].count - Int(fileRate * 0.05) && captured.allSatisfy { $0.allSatisfy(\.isFinite) }
    : result["exact"] as? Bool == true
result["ordinary"] = ordinary
result["passed"] = passed
if !passed, let binary = appBinary { result["stateAtCaptureEnd"] = debug(binary, ["dump_state"]) }
report(result)
let restored = cleanup()
exit(passed && restored ? 0 : 1)

#!/usr/bin/env swift
// Full-file PCM oracle. Start capture before playback; only the first 50 ms
// (the measured player-volume settling interval) is excluded. The marker must
// be non-silent and nonperiodic; use generate-test-audio.sh --render-tests.
//
// <file> <seconds> [device] [--set-rate] [--force-volume] [--play-app <binary>]
// --self-test exercises the SAME comparator without any device or permission.
// --compare <reference> <capture> checks saved captures without hardware.
// --device-check <file> <device> --play-app <binary> [--require-exclusive]
// checks the live mode's negotiation, idle release and format restoration.
// Hardware runs require an idle Debug app already routed to the named device.

import AudioToolbox
import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

// exit() skips Swift defers. Register each acquired resource before the next
// operation can fail, and use the same cleanup for errors and normal exit.
var cleanupActions: [() -> Void] = []
func cleanup() {
    while let action = cleanupActions.popLast() { action() }
}
defer { cleanup() }

func fail(_ message: String) -> Never {
    cleanup()
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}


func compare(_ reference: [[Float]], _ capture: [[Float]], skip: Int) -> [String: Any] {
    guard !reference.isEmpty, reference.count == capture.count,
          let length = reference.first?.count, length > skip + 64,
          reference.allSatisfy({ $0.count == length }),
          let captured = capture.first?.count, capture.allSatisfy({ $0.count == captured }),
          captured >= length - skip else { return ["exact": false, "reason": "incomplete frames or channel mismatch"] }
    guard reference.contains(where: { $0[skip..<(skip + 64)].contains(where: { abs($0) > 1e-5 }) }) else {
        return ["exact": false, "reason": "silent alignment marker; use the seeded noise fixture"]
    }
    var alignment: Int? = nil
    for frame in 0..<(captured - 63) {
        var match = true
        for c in reference.indices {
            for i in 0..<64 where reference[c][skip+i] != capture[c][frame+i] || !capture[c][frame+i].isFinite { match = false; break }
            if !match { break }
        }
        if match { alignment = frame; break }
    }
    guard let start = alignment, start + length - skip <= captured else {
        return ["exact": false, "reason": "missing marker or truncated capture"]
    }
    var mismatches = 0, first = -1
    var peak: Float = 0
    for c in reference.indices {
        for f in skip..<length {
            let value = capture[c][start+f-skip]
            if !value.isFinite || value != reference[c][f] {
                if first < 0 { first = f }
                mismatches += 1
                peak = max(peak, abs(value-reference[c][f]))
            }
        }
    }
    return ["exact": mismatches == 0, "comparedFrames": length-skip, "channels": reference.count,
            "mismatchedSamples": mismatches, "firstBadFrame": first, "maxAbsError": peak.isFinite ? Double(peak) : -1,
            "captureStartFrame": start, "sourceStartFrame": skip]
}
func readPCM(_ url: URL) -> (Double, [[Float]]) {
    do {
        let file = try AVAudioFile(forReading: url)
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
func report(_ result: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
func debug(_ binary: String, _ arguments: [String]) -> [String: Any] {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: binary)
    task.arguments = ["--debug-cmd"] + arguments
    task.standardOutput = pipe
    do { try task.run() } catch { fail("could not run debug client: \(error)") }
    // Drain before waiting so a large state reply cannot fill the pipe.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (json["ok"] as? Bool) != false else { fail("debug command failed: \(arguments)") }
    return json
}

if CommandLine.arguments.contains("--self-test") {
    var reference = [[Float]](repeating: [], count: 2)
    for c in reference.indices {
        for i in 0..<4096 {
            let integer = (i * 7919 + c * 1297) % 65521 - 32760
            reference[c].append(Float(integer) / 131072)
        }
    }
    guard compare(reference, reference, skip: 0)["exact"] as? Bool == true else { fail("identity failed") }
    for name in ["drop", "duplicate", "swap", "gain", "polarity", "clip", "truncate", "silence", "nan", "lsb", "channels", "short"] {
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
        case "nan": bad[1][3000] = Float.nan
        case "lsb": bad[1][3000] += 1 / 8388608
        case "channels": bad.removeLast()
        default: bad = bad.map { Array($0.prefix(128)) }
        }
        guard compare(reference, bad, skip: 0)["exact"] as? Bool == false else { fail("oracle accepted \(name)") }
    }
    report(["selfTest": true, "cases": 13]); exit(0)
}
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--compare" {
    let (rate, reference) = readPCM(URL(fileURLWithPath: CommandLine.arguments[2]))
    let (captureRate, capture) = readPCM(URL(fileURLWithPath: CommandLine.arguments[3]))
    guard rate == captureRate else { fail("capture rate differs from reference") }
    let result = compare(reference, capture, skip: Int(rate * 0.05))
    report(result); exit(result["exact"] as? Bool == true ? 0 : 1)
}
var arguments = Array(CommandLine.arguments.dropFirst())
let deviceCheck = arguments.contains("--device-check")
let requireExclusive = arguments.contains("--require-exclusive")
var appBinary: String? = nil
if let i = arguments.firstIndex(of: "--play-app") {
    guard i+1 < arguments.count else { fail("--play-app needs the Debug binary path") }
    appBinary = arguments[i+1]; arguments.removeSubrange(i...i+1)
}
arguments.removeAll { $0 == "--device-check" || $0 == "--require-exclusive" }
if deviceCheck { arguments.insert("8", at: min(1, arguments.count)) }
let forceVolume = arguments.contains("--force-volume")
// --set-rate: put the device at the file's rate ourselves and back at exit —
// for measuring the everyday chain with the mode OFF, when Vibe does not.
let setRate = arguments.contains("--set-rate")
arguments.removeAll { $0 == "--force-volume" || $0 == "--set-rate" }
guard arguments.count >= 2, let seconds = Double(arguments[1]), seconds.isFinite, seconds > 0, seconds <= 120 else {
    fail("usage: verify-bit-perfect.swift <audio-file> <seconds> [device-name] [--force-volume]")
}
let fileURL = URL(fileURLWithPath: arguments[0])
let deviceName = arguments.count >= 3 ? arguments[2] : "BlackHole 2ch"

// MARK: - HAL helpers

func property(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func deviceNamed(_ name: String) -> AudioDeviceID? {
    var address = property(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
    for id in ids {
        var nameAddress = property(kAudioObjectPropertyName)
        var cfName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfName) == noErr,
           let value = cfName?.takeRetainedValue(), value as String == name { return id }
    }
    return nil
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
    (kAudioDevicePropertyVolumeScalar, 1),
    (kAudioDevicePropertyVolumeScalar, 2),
]

func readVolume(_ device: AudioDeviceID, _ slot: VolumeSlot) -> Float32? {
    var address = AudioObjectPropertyAddress(mSelector: slot.selector, mScope: kAudioObjectPropertyScopeOutput, mElement: slot.element)
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var value: Float32 = 1
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func writeVolume(_ device: AudioDeviceID, _ slot: VolumeSlot, _ volume: Float32) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: slot.selector, mScope: kAudioObjectPropertyScopeOutput, mElement: slot.element)
    var value = volume
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
}

// MARK: - Setup

guard let device = deviceNamed(deviceName) else { fail("no output device named \(deviceName)") }
var restoreVolumes: [(VolumeSlot, Float32)] = []
cleanupActions.append {
    for (slot, volume) in restoreVolumes { _ = writeVolume(device, slot, volume) }
}
for slot in volumeSlots {
    guard let volume = readVolume(device, slot), volume < 0.999 else { continue }
    guard forceVolume else {
        fail("\(deviceName)'s volume is \(volume) (slot \(slot.element)); set it to 100% in Audio MIDI Setup or pass --force-volume")
    }
    guard writeVolume(device, slot, 1.0) else { fail("could not set device volume to unity") }
    restoreVolumes.append((slot, volume))
}

let (fileRate, referenceSamples) = readPCM(fileURL)

if let binary = appBinary {
    let state = debug(binary, ["dump_state"])
    guard let player = state["player"] as? [String: Any],
          player["manualRendering"] as? Bool == false,
          player["silent"] as? Bool == false,
          player["state"] as? String == "stopped",
          (player["outputDeviceId"] as? NSNumber)?.uint32Value == device else {
        fail("Use an idle, unmuted hardware Debug app explicitly routed to \(deviceName)")
    }
    guard (player["pitch"] as? NSNumber)?.doubleValue == 0,
          ["lowKill", "reverbSend", "delaySend", "shortDelaySend"].allSatisfy({ player[$0] as? Bool == false }) else {
        fail("Set pitch to zero and turn every effect off before a transparency capture")
    }
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
    }
    _ = debug(binary, ["set_bit_perfect", "on"])
    _ = debug(binary, ["open", fileURL.path])
    let deadline = Date().addingTimeInterval(10)
    var facts: [String: Any] = [:]
    repeat {
        let live = debug(binary, ["dump_state"])["player"] as? [String: Any] ?? [:]
        facts = live["bitPerfect"] as? [String: Any] ?? [:]
        if facts["status"] as? String == "active" { break }
        Thread.sleep(forTimeInterval: 0.02)
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
    Thread.sleep(forTimeInterval: 6.5)
    let idle = (debug(binary, ["dump_state"])["player"] as? [String: Any])?["bitPerfect"] as? [String: Any] ?? [:]
    guard (idle["hoggedDeviceId"] as? NSNumber)?.uint32Value == 0,
          !requireExclusive || hogOwner(device) == -1 else { fail("idle engine retained exclusive ownership") }
    cleanup()
    let restoreDeadline = Date().addingTimeInterval(2)
    while (nominalRate(device) != before || physicalFormats(device) != formatsBefore) && Date() < restoreDeadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    guard nominalRate(device) == before, physicalFormats(device) == formatsBefore else { fail("device physical format was not restored") }
    for (slot, volume) in restoreVolumes where readVolume(device, slot) != volume { fail("device volume was not restored") }
    report(["deviceCheck": true, "active": facts, "originalRate": before, "restoredRate": nominalRate(device), "physicalFormatsRestored": true])
    exit(0)
}
// MARK: - Capture

// Prepare the file once before binding capture: a bit-perfect format switch
// invalidates an already-bound IOProc. The measured replay begins only AFTER
// capture starts, so the comparator still requires the complete source tail.
if let binary = appBinary {
    cleanupActions.append { _ = debug(binary, ["quiesce"]) }
    let player = debug(binary, ["dump_state"])["player"] as? [String: Any] ?? [:]
    if (player["bitPerfect"] as? [String: Any])?["enabled"] as? Bool == true {
        _ = debug(binary, ["open", fileURL.path])
        let ready = Date().addingTimeInterval(10)
        while nominalRate(device) != fileRate && Date() < ready { Thread.sleep(forTimeInterval: 0.02) }
        Thread.sleep(forTimeInterval: 0.2)
        _ = debug(binary, ["quiesce"])
    }
}
// --set-rate is for regular mode; it restores the original nominal rate.
var restoreRate: Double? = nil
cleanupActions.append {
    if let rate = restoreRate {
        var rateAddress = property(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        _ = AudioObjectSetPropertyData(device, &rateAddress, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
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
    Thread.sleep(forTimeInterval: 0.05)
}
if nominalRate(device) != fileRate {
    fail("\(deviceName) never reached \(fileRate) Hz (it is at \(nominalRate(device)))")
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
guard captureIsFloat, virtualFormat.mBitsPerChannel == 32, captureChannels > 0,
      captureRate.isFinite, captureRate > 0, captureRate <= 384000 else {
    fail("\(deviceName)'s input virtual format is not float32: \(virtualFormat)")
}
// Bound memory before starting IO. The callback never allocates or waits on
// a lock; release/acquire publishes only the fully copied prefix.
let capacity = Int(captureRate * (15 + seconds + 1))
let storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity * captureChannels)
storage.initialize(repeating: 0, count: capacity * captureChannels)
cleanupActions.append { storage.deallocate() }
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
        guard Int(buffer.mNumberChannels) == captureChannels else { overflowed.store(true, ordering: .relaxed); return noErr }
        storage.advanced(by: start*captureChannels).update(from: data.assumingMemoryBound(to: Float.self), count: frames*captureChannels)
    } else {
        guard list.count == captureChannels else { overflowed.store(true, ordering: .relaxed); return noErr }
        for c in 0..<captureChannels {
            guard let data = list[c].mData, Int(list[c].mDataByteSize)/4 == frames else { overflowed.store(true, ordering: .relaxed); return noErr }
            let samples = data.assumingMemoryBound(to: Float.self)
            for f in 0..<frames { storage[(start+f)*captureChannels+c] = samples[f] }
        }
    }
    writtenFrames.store(start+frames, ordering: .releasing)
    return noErr
}
var procID: AudioDeviceIOProcID? = nil
guard AudioDeviceCreateIOProcID(device, ioProc, nil, &procID) == noErr, let proc = procID else {
    fail("could not create an IOProc on \(deviceName)")
}
let stopCapture = {
    if let activeProc = procID {
        AudioDeviceStop(device, activeProc)
        AudioDeviceDestroyIOProcID(device, activeProc)
        procID = nil
    }
}
cleanupActions.append(stopCapture)
guard AudioDeviceStart(device, proc) == noErr else { fail("could not start IO on \(deviceName)") }

FileHandle.standardError.write(Data("Capture ready on \(deviceName)\n".utf8))
if let binary = appBinary {
    _ = debug(binary, ["open", fileURL.path])
}

// Wait for audio, then record for `seconds` from the first non-silent frame.
let deadline = Date().addingTimeInterval(15)
var audioSeen = false
while Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
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
Thread.sleep(forTimeInterval: seconds)
stopCapture()

// MARK: - Compare
let capturedFrames = writtenFrames.load(ordering: .acquiring)
guard !overflowed.load(ordering: .relaxed), captureRate == fileRate else { fail("capture overflow, layout change or rate mismatch") }
var captured = [[Float]](repeating: [Float](repeating: 0, count: capturedFrames), count: captureChannels)
for c in 0..<captureChannels { for f in 0..<capturedFrames { captured[c][f] = storage[f*captureChannels+c] } }
var result = compare(referenceSamples, captured, skip: Int(fileRate*0.05))
result["device"] = deviceName
result["captureRate"] = captureRate
result["fileRate"] = fileRate
result["capturedFrames"] = capturedFrames
result["forcedVolumeSlots"] = restoreVolumes.count
report(result)
cleanup()
exit(result["exact"] as? Bool == true ? 0 : 1)

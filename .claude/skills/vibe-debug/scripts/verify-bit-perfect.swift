#!/usr/bin/env swift
//
// verify-bit-perfect.swift — the loopback oracle for bit-perfect output.
//
// Records a virtual output device (BlackHole 2ch by default) for N seconds
// while Vibe plays a file through it, then compares the capture against the
// file's own decoded samples: finds where the capture's audio sits inside the
// file and counts every frame that differs from there on. Zero mismatches at
// the file's own rate means nothing between the decoder and the device
// changed a bit — no resampling, no gain, no varispeed, no FX.
//
//   swift verify-bit-perfect.swift <audio-file> <seconds> [device-name] [--force-volume]
//
// Start it BEFORE `--debug-cmd open <file>` (it waits up to 15 s for audio to
// appear) or during playback; the alignment search handles a capture that
// starts mid-file. The device's software volume must read 1.0, or the HAL
// scales the samples before they reach the device: the script refuses
// otherwise, unless --force-volume, which sets it to 1.0 for the run and puts
// the old value back at exit. Prints one JSON line: {captureRate, fileRate,
// alignedAtFrame, comparedFrames, mismatches, maxAbsError, exact}.
//

import AVFoundation
import CoreAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let forceVolume = arguments.contains("--force-volume")
// --set-rate: put the device at the file's rate ourselves and back at exit —
// for measuring the everyday chain with the mode OFF, when Vibe does not.
let setRate = arguments.contains("--set-rate")
arguments.removeAll { $0 == "--force-volume" || $0 == "--set-rate" }
guard arguments.count >= 2, let seconds = Double(arguments[1]) else {
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
        var cfName: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        if AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfName) == noErr, (cfName as String) == name {
            return id
        }
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

let virtualMainVolume: AudioObjectPropertySelector = 0x766d7663 // 'vmvc', kAudioHardwareServiceDeviceProperty_VirtualMainVolume

func softwareVolume(_ device: AudioDeviceID) -> Float32? {
    var address = property(virtualMainVolume, kAudioObjectPropertyScopeOutput)
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var volume: Float32 = 1
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
    return volume
}

func setSoftwareVolume(_ device: AudioDeviceID, _ volume: Float32) -> Bool {
    var address = property(virtualMainVolume, kAudioObjectPropertyScopeOutput)
    var value = volume
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
}

// The device's own volume scalars (kAudioDevicePropertyVolumeScalar) on the
// main element and each output channel: a driver that applies these itself —
// BlackHole does — scales the samples before they loop back, so the oracle
// has to hold them at 1.0 too.
func volumeScalarElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
    var elements: [AudioObjectPropertyElement] = []
    for element in [kAudioObjectPropertyElementMain, 1, 2] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                 mScope: kAudioObjectPropertyScopeOutput, mElement: element)
        if AudioObjectHasProperty(device, &address) { elements.append(element) }
    }
    return elements
}

func volumeScalar(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Float32? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                             mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    var value: Float32 = 1
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func setVolumeScalar(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement, _ volume: Float32) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                             mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    var value = volume
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
}

// MARK: - Setup

guard let device = deviceNamed(deviceName) else { fail("no output device named \(deviceName)") }
var restoreVolume: Float32? = nil
if let volume = softwareVolume(device), volume < 0.999 {
    if forceVolume {
        guard setSoftwareVolume(device, 1.0) else { fail("could not set \(deviceName)'s software volume") }
        restoreVolume = volume
    } else {
        fail("\(deviceName)'s software volume is \(volume); set it to 100% in Audio MIDI Setup or pass --force-volume")
    }
}
var restoreScalars: [(AudioObjectPropertyElement, Float32)] = []
for element in volumeScalarElements(device) {
    guard let volume = volumeScalar(device, element), volume < 0.999 else { continue }
    if forceVolume {
        if setVolumeScalar(device, element, 1.0) { restoreScalars.append((element, volume)) }
    } else {
        fail("\(deviceName)'s volume scalar on element \(element) is \(volume); set it to 100% or pass --force-volume")
    }
}
defer {
    if let volume = restoreVolume { _ = setSoftwareVolume(device, volume) }
    for (element, volume) in restoreScalars { _ = setVolumeScalar(device, element, volume) }
}

let reference: AVAudioFile
do {
    reference = try AVAudioFile(forReading: fileURL)
} catch {
    fail("could not open \(fileURL.path): \(error)")
}
let fileRate = reference.processingFormat.sampleRate
let channels = Int(reference.processingFormat.channelCount)
let referenceLength = AVAudioFrameCount(reference.length)
guard let referenceBuffer = AVAudioPCMBuffer(pcmFormat: reference.processingFormat, frameCapacity: referenceLength) else {
    fail("could not allocate the reference buffer")
}
do { try reference.read(into: referenceBuffer) } catch { fail("could not read \(fileURL.path): \(error)") }
guard let referenceData = referenceBuffer.floatChannelData else { fail("reference is not float PCM") }

// MARK: - Capture

// Vibe switches the device to the file's rate when the track settles; a
// capture bound before that would be torn down by the switch. So wait for the
// device to reach the file's rate first, then record straight from the HAL
// with an IOProc — no AVAudioEngine, whose input node follows the default
// input device rather than the one asked for.
var restoreRate: Double? = nil
if setRate && nominalRate(device) != fileRate {
    restoreRate = nominalRate(device)
    var rateAddress = property(kAudioDevicePropertyNominalSampleRate)
    var wanted = fileRate
    guard AudioObjectSetPropertyData(device, &rateAddress, 0, nil, UInt32(MemoryLayout<Float64>.size), &wanted) == noErr else {
        fail("could not set \(deviceName) to \(fileRate) Hz")
    }
}
defer {
    if let rate = restoreRate {
        var rateAddress = property(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        _ = AudioObjectSetPropertyData(device, &rateAddress, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
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
guard captureIsFloat, virtualFormat.mBitsPerChannel == 32 else {
    fail("\(deviceName)'s input virtual format is not float32: \(virtualFormat)")
}
var captured = [[Float]](repeating: [], count: captureChannels)
var callbacks = 0
let captureLock = NSLock()

let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, _ in
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    captureLock.lock()
    callbacks += 1
    if captureInterleaved, let first = list.first, let data = first.mData {
        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (4 * max(channels, 1))
        let samples = data.assumingMemoryBound(to: Float.self)
        for channel in 0..<min(channels, captureChannels) {
            var i = channel
            captured[channel].reserveCapacity(captured[channel].count + frames)
            for _ in 0..<frames {
                captured[channel].append(samples[i])
                i += channels
            }
        }
    } else {
        for (channel, buffer) in list.enumerated() where channel < captureChannels {
            guard let data = buffer.mData else { continue }
            let frames = Int(buffer.mDataByteSize) / 4
            captured[channel].append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames))
        }
    }
    captureLock.unlock()
    return noErr
}
var procID: AudioDeviceIOProcID? = nil
guard AudioDeviceCreateIOProcID(device, ioProc, nil, &procID) == noErr, let proc = procID else {
    fail("could not create an IOProc on \(deviceName)")
}
guard AudioDeviceStart(device, proc) == noErr else { fail("could not start IO on \(deviceName)") }

// Wait for audio, then record for `seconds` from the first non-silent frame.
let deadline = Date().addingTimeInterval(15)
var audioSeen = false
while Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
    captureLock.lock()
    let heard = captured[0].contains { abs($0) > 1e-6 }
    captureLock.unlock()
    if heard { audioSeen = true; break }
}
if !audioSeen {
    AudioDeviceStop(device, proc)
    captureLock.lock()
    let frames = captured[0].count
    captureLock.unlock()
    // Frames with a zero peak means the device delivered silence — on macOS
    // that is what a process without microphone permission hears from ANY
    // input, a virtual loopback included. No frames at all means IO never ran.
    fail("no audio arrived on \(deviceName) within 15 s (\(callbacks) callbacks, \(frames) frames)")
}
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(device, proc)
AudioDeviceDestroyIOProcID(device, proc)

// MARK: - Compare

let compareChannels = min(channels, captureChannels)
let capture = captured
let captureLength = capture[0].count
// The capture's own first clearly non-silent frame, plus a margin past the
// player's declick fade-in, is the window we look for inside the reference.
guard let firstAudible = capture[0].firstIndex(where: { abs($0) > 1e-3 }) else {
    fail("the capture never rose above silence")
}
let windowStart = min(firstAudible + Int(captureRate * 0.05), captureLength - 64)
let window = 64
var alignedAt = -1
if captureRate == fileRate && windowStart + window <= captureLength {
    let needle = Array(capture[0][windowStart..<(windowStart + window)])
    let ref0 = referenceData[0]
    let limit = Int(referenceLength) - window
    var j = 0
    while j <= limit {
        if ref0[j] == needle[0] {
            var k = 1
            while k < window && ref0[j + k] == needle[k] { k += 1 }
            if k == window { alignedAt = j; break }
        }
        j += 1
    }
}
// Diagnostics for a failed exact alignment: a tolerant search says whether
// the audio is there but scaled or dithered, and the peak ratio says by how
// much.
var approxAlignedAt = -1
var approxMaxError: Float = 0
if alignedAt < 0 && captureRate == fileRate && windowStart + window <= captureLength {
    let needle = Array(capture[0][windowStart..<(windowStart + window)])
    let ref0 = referenceData[0]
    let limit = Int(referenceLength) - window
    let tolerance: Float = 0.002
    var j = 0
    outer: while j <= limit {
        var worst: Float = 0
        for k in 0..<window {
            let d = abs(ref0[j + k] - needle[k])
            if d > tolerance { j += 1; continue outer }
            worst = max(worst, d)
        }
        approxAlignedAt = j
        approxMaxError = worst
        break
    }
}
let capturePeak = capture[0].map { abs($0) }.max() ?? 0
let referencePeak = (0..<Int(referenceLength)).reduce(Float(0)) { max($0, abs(referenceData[0][$1])) }

var compared = 0
var mismatches = 0
var maxAbsError: Float = 0
if alignedAt >= 0 {
    let available = min(Int(referenceLength) - alignedAt, captureLength - windowStart)
    for channel in 0..<compareChannels {
        let ref = referenceData[channel]
        let cap = capture[channel]
        for i in 0..<available {
            let a = ref[alignedAt + i], b = cap[windowStart + i]
            if a != b {
                mismatches += 1
                maxAbsError = max(maxAbsError, abs(a - b))
            }
        }
    }
    compared = available * compareChannels
}
let result: [String: Any] = [
    "device": deviceName,
    "captureRate": captureRate,
    "fileRate": fileRate,
    "alignedAtFrame": alignedAt,
    "comparedFrames": compared,
    "mismatches": mismatches,
    "maxAbsError": Double(maxAbsError),
    "exact": alignedAt >= 0 && mismatches == 0 && compared > 0,
    "approxAlignedAtFrame": approxAlignedAt,
    "approxMaxError": Double(approxMaxError),
    "capturePeak": Double(capturePeak),
    "referencePeak": Double(referencePeak),
    "forcedScalars": restoreScalars.map { "\($0.0)=\($0.1)" },
]
let json = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(data: json, encoding: .utf8)!)

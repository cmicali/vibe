// The measurement behind the output-unit follow that taking the system default
// causes, and the settle that answers it (Audio/Mac/Devices/CLAUDE.md;
// docs/future/bit-perfect-output.md, system-output experiment). Run it against
// the device that IS the default, or let it make one the default for the run:
//
//   hogfollow <deviceID> [engine|hal] [--make-default]
//
// `engine` (the default) is AVAudioEngine's own output node, a default output
// unit whatever device it was pinned to. `hal` is the Stage 2 candidate: an
// explicitly hosted HALOutput unit whose render callback would pull the engine
// in realtime manual-rendering mode. Both count IO cycles, because `running`
// alone is not success — a unit started while a follow is in flight reports
// running and then never gets an IO cycle.
//
// Phase 1, running: does hogging the default move the default, and does the
// unit follow it off the device it was bound to? Does a re-bind stick while
// the hog is held, and what does the release do? Phase 2, stopped: after a hog
// and a re-bind, does the first start apply a pending follow, does a second
// start stick, and (engine only) does prepare() before the start absorb it?
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

let device = AudioDeviceID(CommandLine.arguments[1])!
let useHAL = CommandLine.arguments.contains("hal")
let makeDefault = CommandLine.arguments.contains("--make-default")

func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func owner() -> pid_t {
    var a = addr(kAudioDevicePropertyHogMode)
    var p: pid_t = -2; var s = UInt32(MemoryLayout<pid_t>.size)
    AudioObjectGetPropertyData(device, &a, 0, nil, &s, &p); return p
}
func writeHog(_ v: pid_t) -> OSStatus {
    var a = addr(kAudioDevicePropertyHogMode)
    var value = v
    return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<pid_t>.size), &value)
}
func systemDefault() -> AudioDeviceID {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var d: AudioDeviceID = 0; var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d); return d
}
func setSystemDefault(_ d: AudioDeviceID) -> OSStatus {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var value = d
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
}
func nominalRate() -> Double {
    var a = addr(kAudioDevicePropertyNominalSampleRate)
    var r: Double = 0; var s = UInt32(MemoryLayout<Double>.size)
    AudioObjectGetPropertyData(device, &a, 0, nil, &s, &r); return r
}

// IO cycles, counted by whichever render path is under test.
var renders: Int64 = 0
var rendersAtLastLine: Int64 = 0

// The engine path: its output node, pinned to the device, fed by a silent
// source node so every IO cycle is counted.
let engine = AVAudioEngine()
let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
    renders += 1
    for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    return noErr
}

// The HAL path: an explicit HALOutput unit, the Stage 2 candidate.
var halUnit: AudioUnit? = nil
let halCallback: AURenderCallback = { _, ioActionFlags, _, _, _, ioData in
    renders += 1
    if let ioData = ioData {
        for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
    ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}
func makeHALUnit() -> AudioUnit {
    var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                componentSubType: kAudioUnitSubType_HALOutput,
                                                componentManufacturer: kAudioUnitManufacturer_Apple,
                                                componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else { fatalError("no HALOutput component") }
    var unit: AudioUnit? = nil
    let created = AudioComponentInstanceNew(component, &unit)
    guard created == noErr, let hal = unit else { fatalError("HALOutput instance: \(created)") }
    var enable: UInt32 = 1
    AudioUnitSetProperty(hal, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, 4)
    var disable: UInt32 = 0
    AudioUnitSetProperty(hal, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, 4)
    return hal
}

var unit: AudioUnit! = useHAL ? makeHALUnit() : engine.outputNode.audioUnit!
func unitDevice() -> AudioDeviceID {
    var d: AudioDeviceID = 0; var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, &s); return d
}
func bind() -> OSStatus {
    var d = device
    return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
}
func running() -> Bool {
    if !useHAL { return engine.isRunning }
    var r: UInt32 = 0; var s = UInt32(4)
    AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &r, &s); return r != 0
}
let t0 = Date()
func stamp() -> String { String(format: "%6.0f ms", Date().timeIntervalSince(t0) * 1000) }
func line(_ what: String) {
    let delta = renders - rendersAtLastLine
    rendersAtLastLine = renders
    print("\(stamp()) \(what): default \(systemDefault()) unit \(unitDevice()) running \(running()) hog \(owner()) renders +\(delta)")
}
var notifications = 0
if !useHAL {
    NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
        notifications += 1
        line("  NOTIFICATION #\(notifications)")
    }
}
func poll(_ what: String, _ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        line(what)
    }
}
func start(_ label: String) {
    let began = Date()
    if useHAL {
        let status = AudioOutputUnitStart(unit)
        print("\(stamp()) \(label): start \(status == noErr ? "ok" : "FAILED \(status)") in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
    } else {
        do { try engine.start(); print("\(stamp()) \(label): start ok in \(Int(Date().timeIntervalSince(began) * 1000)) ms") }
        catch { print("\(stamp()) \(label): start FAILED \(error)") }
    }
}
func stop() {
    if useHAL { AudioOutputUnitStop(unit) } else { engine.stop() }
}

let previousDefault = systemDefault()
if makeDefault && previousDefault != device {
    print("make default: \(setSystemDefault(device)) (was \(previousDefault))")
    Thread.sleep(forTimeInterval: 0.5)
}
defer {
    _ = writeHog(-1)
    stop()
    if makeDefault && previousDefault != device {
        print("restore default: \(setSystemDefault(previousDefault))")
    }
}

if useHAL {
    print("bind: \(bind())")
    var format = AudioStreamBasicDescription(mSampleRate: nominalRate(), mFormatID: kAudioFormatLinearPCM,
                                             mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                             mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                             mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    print("format \(Int(format.mSampleRate)) Hz: \(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))")
    var callback = AURenderCallbackStruct(inputProc: halCallback, inputProcRefCon: nil)
    print("callback: \(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))")
    print("initialize: \(AudioUnitInitialize(unit))")
} else {
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: nominalRate(), channels: 2))
    print("bind: \(bind())")
}
print("me \(getpid()); device \(device); mode \(useHAL ? "hal" : "engine"); default at start \(systemDefault())")
start("initial")
poll("idle", 0.75)

print("==== phase 1: hog while running")
print("hog: \(writeHog(getpid()))")
poll("after hog", 2.0)
print("re-bind: \(bind())")
poll("after re-bind", 2.0)
print("release: \(writeHog(-1))")
poll("after release", 1.5)
stop()

print("==== phase 2: hog while stopped, re-bind, first and second start")
print("hog: \(writeHog(getpid()))")
poll("hogged, stopped", 0.75)
print("re-bind: \(bind())")
start("first start after hog")
poll("after first start", 2.0)
print("re-bind again: \(bind())")
start("second start")
poll("after second start", 2.0)
print("release: \(writeHog(-1))")
poll("released", 1.0)
stop()

if !useHAL {
    print("==== phase 2b: hog while stopped, re-bind, prepare(), then start")
    print("hog: \(writeHog(getpid()))")
    poll("hogged, stopped", 0.75)
    print("re-bind: \(bind())")
    engine.prepare()
    line("after prepare")
    start("start after prepare")
    poll("after start", 2.0)
    print("release: \(writeHog(-1))")
    poll("released", 0.75)
    stop()
}

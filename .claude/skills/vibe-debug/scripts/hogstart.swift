// After hogging the default device with the engine stopped and re-binding the
// unit: does the first start flip the unit back to the (moved) default, does
// a second start stick, and does engine.prepare() absorb it? Usage: hogstart <deviceID>
import AVFoundation
import CoreAudio
import Foundation

let device = AudioDeviceID(CommandLine.arguments[1])!
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
let engine = AVAudioEngine()
let unit = engine.outputNode.audioUnit!
func unitDevice() -> AudioDeviceID {
    var d: AudioDeviceID = 0; var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, &s); return d
}
func bind() -> OSStatus {
    var d = device
    return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
}
let t0 = Date()
func stamp() -> String { String(format: "%6.0f ms", Date().timeIntervalSince(t0) * 1000) }
func line(_ what: String) {
    print("\(stamp()) \(what): default \(systemDefault()) unit \(unitDevice()) running \(engine.isRunning) hog \(owner())")
}
var notifications = 0
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
    notifications += 1
    line("  NOTIFICATION #\(notifications)")
}
func poll(_ what: String, _ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        line(what)
    }
}
func start(_ label: String) {
    do { try engine.start(); print("\(stamp()) \(label): start ok") }
    catch { print("\(stamp()) \(label): start FAILED \(error)") }
}
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: nil)
print("me \(getpid()); device \(device); default at start \(systemDefault())")
print("bind: \(bind())")
start("initial")
poll("idle", 0.75)
engine.stop()
line("stopped")
print("---- hog while stopped: \(writeHog(getpid()))")
poll("hogged, stopped", 0.75)
print("---- re-bind: \(bind())")
start("first start after hog")
poll("after first start", 2.0)
print("---- re-bind again: \(bind())")
start("second start")
poll("after second start", 2.0)
print("---- release: \(writeHog(-1))")
poll("released", 1.0)
engine.stop()
print("---- variant: hog stopped, re-bind, prepare(), then start")
print("hog: \(writeHog(getpid()))")
poll("hogged, stopped", 0.75)
print("re-bind: \(bind())")
engine.prepare()
line("after prepare")
start("start after prepare")
poll("after start", 2.0)
print("---- release: \(writeHog(-1))")
poll("released", 0.75)
engine.stop()

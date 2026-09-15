// Does hogging the system default output device move the default, and does
// AVAudioEngine's output unit follow the default away from the device it was
// explicitly bound to? Then: does a re-bind stick while the hog is held, and
// what happens on release? Usage: hogfollow <deviceID>
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
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: nil)
print("me \(getpid()); device \(device); default at start \(systemDefault())")
print("bind: \(bind())")
try! engine.start()
line("started")
poll("idle", 1.0)
print("---- hog \(device) while running: \(writeHog(getpid()))")
poll("after hog", 3.0)
print("---- re-bind: \(bind())")
poll("after re-bind", 3.0)
print("---- release: \(writeHog(-1))")
poll("after release", 3.0)
print("---- hog again with the engine STOPPED, then re-bind, then start")
engine.stop()
print("hog: \(writeHog(getpid()))")
poll("stopped+hogged", 1.5)
print("re-bind: \(bind())")
try! engine.start()
poll("started hogged", 3.0)
print("---- release while running")
print("release: \(writeHog(-1))")
poll("after release 2", 2.0)
engine.stop()

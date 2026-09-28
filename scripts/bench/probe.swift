// The benchmark's launch probe: spawns the app and times its first on-screen
// window, the one number no channel verb can give, since the channel itself
// comes up with the app.
//
// Usage: probe <executable> [args ...]
//        probe --device-id <CoreAudio device UID>
// Prints {"pid": N, "t0": ns, "windowNs": ns} on stdout and exits, leaving
// the app running. t0 and windowNs are CLOCK_UPTIME_RAW, the clock Python's
// time.monotonic_ns() reads on macOS. The child inherits this environment.
// Window owner and bounds need no Screen Recording permission; titles would.
import CoreAudio
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    FileHandle.standardError.write("usage: probe <executable> [args ...] | probe --device-id <uid>\n".data(using: .utf8)!)
    exit(64)
}

// `probe --device-id <uid>`: the CoreAudio object ID of the device with that
// UID, which the app's dump_state reports as the device it is bound to, then a
// tab and its name, which differs by Mac model.
if args[0] == "--device-id", args.count == 2 {
    var translation: AudioObjectID = 0
    var uid = args[1] as CFString
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &translation)
    }
    guard status == 0, translation != 0 else {
        print(0)
        exit(1)
    }
    var name: Unmanaged<CFString>?
    var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(translation, &nameAddress, 0, nil, &nameSize, &name)
    print("\(translation)\t\((name?.takeRetainedValue() as String?) ?? "")")
    exit(0)
}
var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
var pid: pid_t = 0
// The app outlives the probe, so it must not hold the probe's stdout: the
// caller reads that pipe to EOF.
var actions: posix_spawn_file_actions_t?
posix_spawn_file_actions_init(&actions)
for fd: Int32 in [0, 1, 2] {
    posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
}
let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
let status = posix_spawn(&pid, args[0], &actions, nil, &argv, environ)
guard status == 0 else {
    FileHandle.standardError.write("posix_spawn failed: \(status)\n".data(using: .utf8)!)
    exit(1)
}

var windowNs: UInt64 = 0
let deadline = t0 + 30_000_000_000
while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let shown = list.contains { info in
        (info[kCGWindowOwnerPID as String] as? Int32) == pid && (info[kCGWindowLayer as String] as? Int) == 0
    }
    if shown {
        windowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        break
    }
    var exitStatus: Int32 = 0
    if waitpid(pid, &exitStatus, WNOHANG) == pid {
        break
    }
    usleep(2000)
}
print("{\"pid\": \(pid), \"t0\": \(t0), \"windowNs\": \(windowNs)}")

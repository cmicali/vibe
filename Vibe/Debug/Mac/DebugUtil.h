//
//  DebugUtil.h
//  Vibe
//

#import <Foundation/Foundation.h>

#if DEBUG

// C linkage, so an ObjC++ importer (DebugBPMScan.mm here) agrees with the
// plain-ObjC files on unmangled names.
#ifdef __cplusplus
extern "C" {
#endif

// Installs a notification hook that dumps the key window (else the main
// window, else the first visible one) to a PNG. Trigger from a terminal:
//
//     notifyutil -p com.vibe.debug.screenshot
//
// then read vibe-screenshot.png from the app container's tmp directory. The
// app is sandboxed, so /tmp is not writable:
//
//     ~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/
//
// It renders the window's layer tree in-process, with no window-server
// capture, so it needs no screen-recording permission and works with the
// display asleep or the window occluded. NSGlassEffectView layers cannot
// render this way: they are hidden, over an appearance-matched flat fill.
// Hiding them forces a model-tree render, so a glass-bearing window's
// animations land at their target values; glass-free windows render the
// presentation tree mid-flight. Metal content (the About window) does not
// render either.
void VibeInstallDebugScreenshotHook(void);

// Debug command channel: the Vibe binary doubles as its own CLI client.
//
//     .../Vibe.app/Contents/MacOS/Vibe --debug-cmd dump_state
//     .../Vibe.app/Contents/MacOS/Vibe --debug-cmd set_pitch -4.5
//
// The client writes a JSON command file, {"id", "args": [verb, arg, ...]},
// into the sandbox container's tmp; the direct-exec'd client runs in the same
// container, so it needs no permission. args stays an array end to end, never
// joined and re-tokenized, so paths with any whitespace survive byte-exact.
// The client then pokes the app with a darwin notification — the payload
// cannot ride it: darwin notifications carry none, and a sandboxed process may
// not post distributed notifications with userInfo — and polls for a
// per-command response file.
//
// VibeDebugCommandTable (DebugCommandTable.m) merged with the shared table
// (DebugCommonVerbs.m) is the authoritative verb list: each entry carries its
// usage string, client wait and handler, and dispatch and the unknown-command
// reply both derive from it. Usage docs: the vibe-debug skill's
// references/mac-verbs.md.

// The app side; call it at launch. Listens on com.vibe.debug.command, on the
// main queue.
void VibeInstallDebugCommandHook(void);

// The cores of `scan_bpm` and `scan_key`, in DebugBPMScan.mm (ObjC++, for the
// waveform mono mix). Each decodes the file and runs its analyzer in the
// calling process, returning one JSON object with a timing split:
// {"ok","bpm"} where bpm 0 means no confident tempo, {"ok","key","camelot",
// "index"} where empty names and index -1 mean no confident key, or {"error"}.
//
// They touch no app state, so the CLI client runs these verbs locally: they
// work with no app running and never touch a running instance. The
// command-table entries run the same functions app-side for callers that
// post the command file directly.
//
// Sandbox: the running app reads only paths it has been granted, and the
// direct-exec'd client only its container. So scan-bpm.sh and scan-key.sh
// stream the file through stdin (`scan_bpm -`) and the client stages it in
// the container tmp.
NSString *VibeDebugBPMScanJSON(NSString *rawPath);
NSString *VibeDebugKeyScanJSON(NSString *rawPath);

// The client side, in DebugClient.m. main() invokes it for
// `Vibe --debug-cmd ...` before NSApplicationMain, so no second app instance
// ever starts. Returns the process exit code: 0 ok, 1 no response or I/O
// failure, 2 command error, 64 usage.
int VibeDebugCommandClientMain(int argc, const char *argv[]);

#ifdef __cplusplus
}
#endif

#endif

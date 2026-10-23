//
//  DebugMacEntry.h
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
// VibeDebugCommandTable (DebugMacVerbs.m and its topic tables) merged with
// the shared table (Vibe/Debug/Verbs/) is the authoritative verb list: each entry carries its
// usage string, client wait and handler, and dispatch and the unknown-command
// reply both derive from it. Usage docs: the vibe-debug skill's
// references/mac-verbs.md.

// The app side; call it at launch. Listens on com.vibe.debug.command, on the
// main queue.
void VibeInstallDebugCommandHook(void);

// The client side, in DebugClient.m. main() invokes it for
// `Vibe --debug-cmd ...` before NSApplicationMain, so no second app instance
// ever starts. Returns the process exit code: 0 ok, 1 no response or I/O
// failure, 2 command error, 64 usage.
int VibeDebugCommandClientMain(int argc, const char *argv[]);

// The spec for verb in either table the app dispatches with. The client reads
// its clientTimeout, so its wait derives from the table the app uses.
NSDictionary *VibeCommandSpecForVerb(NSString *verb);

#ifdef __cplusplus
}
#endif

#endif

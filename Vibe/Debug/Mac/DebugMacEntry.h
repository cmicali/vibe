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
// The shared table (Vibe/Debug/Verbs/), the standard and input tables
// (Standard/), and VibeDebugCommandTable (DebugMacVerbs.m and its topic
// tables) are the authoritative verb list: each entry carries its usage
// string, client wait and handler, and dispatch and the unknown-command reply
// both derive from them. Usage docs: the vibe-debug skill's
// references/mac-verbs.md.

// The app side; call it at launch. Installs the channel under the app's bundle
// identifier, so it listens on <bundle id>.debug.command, on the main queue.
void VibeInstallDebugCommandHook(void);

// The client side, in DebugClientLocalVerbs.m: Vibe's options and local verbs
// over the client (Channel/DebugClient.h). main() invokes it for
// `Vibe --debug-cmd ...` before NSApplicationMain, so no second app instance
// ever starts. Returns the process exit code: 0 ok, 1 no response or I/O
// failure, 2 command error, 64 usage.
int VibeDebugCommandClientMain(int argc, const char *argv[]);

// The spec for verb in any table the app dispatches with. The client reads
// its clientTimeout, so its wait derives from the table the app uses.
NSDictionary *VibeCommandSpecForVerb(NSString *verb);

#ifdef __cplusplus
}
#endif

#endif

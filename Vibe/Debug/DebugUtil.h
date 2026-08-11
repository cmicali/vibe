//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

#if DEBUG

// The implementations in DebugUtil.m and DebugClient.m, and the callers in
// main.m and AppDelegate.m, are all plain ObjC today. The C-linkage guard
// stays so that an ObjC++ importer would still agree with them on the
// unmangled names.
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
// It renders the window's layer tree in-process, with no window server
// capture, so it needs no screen-recording permission and works with the
// display asleep or the window occluded. NSGlassEffectView and
// NSVisualEffectView layers cannot render this way: they are hidden and
// painted over with an appearance-matched flat proxy fill. Hiding them also
// forces a *model*-tree render on glass-bearing windows, so animations land at
// their target values, while glass-free windows still render the presentation
// tree mid-flight. Metal content, such as the About window, does not render
// either.
void VibeInstallDebugScreenshotHook(void);

// Debug command channel: the Vibe binary doubles as its own CLI client.
//
//     .../Vibe.app/Contents/MacOS/Vibe --debug-cmd dump_state
//     .../Vibe.app/Contents/MacOS/Vibe --debug-cmd set_pitch -4.5
//
// The transport works like this. The client writes a JSON command file,
// {"id", "args": [verb, arg, ...]}, into the sandbox container's tmp; the
// direct-exec'd client runs in the same container, so it needs no permission.
// args stays an array end to end, never joined and re-tokenized, so quoted
// paths with any whitespace survive byte-exact. The client then pokes the
// running app with a darwin notification, because the payload cannot ride the
// notification itself: darwin notifications carry none, and a sandboxed
// process may not post distributed notifications with userInfo. Finally it
// polls for a per-command response file and prints it.
//
// The command set covers inspection dumps (dump_*), transport and UI actions,
// opening files, and per-file waveform-cache control. VibeDebugCommandTable in
// DebugUtil.m is the authoritative list: one entry per verb, carrying its
// usage string, its per-verb client wait and its handler, and both dispatch
// and the unknown-command reply derive from it. The usage docs live in
// .claude/skills/vibe-debug/SKILL.md.

// The app side; call it at launch. It listens on com.vibe.debug.command, on
// the main queue.
void VibeInstallDebugCommandHook(void);

// The cores of the `scan_bpm` and `scan_key` debug commands. Each decodes the
// file and runs its analyzer in the calling process, returning one JSON
// object: {"ok","bpm"} where bpm 0 means no confident tempo, {"ok","key",
// "camelot","index"} where empty strings and index -1 mean no confident key,
// or {"error"}.
//
// They are pure decode and analyze with no app state, so the CLI client runs
// these verbs locally: `Vibe --debug-cmd scan_bpm <file>` works with no app
// running and never touches a running instance. The command-table entries run
// the same functions app-side for callers that post the command file directly.
//
// Sandbox caveat: the running process can read only the paths it has been
// granted, and the direct-exec'd client is limited to the app container. So
// scan-bpm.sh and scan-key.sh stream the file through stdin, in the
// `scan_bpm -` form, and the client stages it in the container tmp.
//
// They are implemented in DebugBPMScan.mm, which needs the C++ waveform
// mono-mix header that DebugUtil.m must not import.
NSString *VibeDebugBPMScanJSON(NSString *rawPath);
NSString *VibeDebugKeyScanJSON(NSString *rawPath);

// The client side, in DebugClient.m. main() invokes it for
// `Vibe --debug-cmd ...` before NSApplicationMain, so no second app instance
// ever starts. It returns the process exit code: 0 ok, 1 no response,
// 2 command error, 64 usage.
int VibeDebugCommandClientMain(int argc, const char *argv[]);

#ifdef __cplusplus
}
#endif

#endif

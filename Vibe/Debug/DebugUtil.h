//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

#if DEBUG

// The implementation (DebugUtil.m) and callers (main.m, AppDelegate.m) are
// plain ObjC today; the C-linkage guard stays so an ObjC++ importer would
// still agree with them on the unmangled names.
#ifdef __cplusplus
extern "C" {
#endif

// Installs a notification hook that dumps the frontmost window to a PNG.
// Trigger from a terminal:
//
//     notifyutil -p com.vibe.debug.screenshot
//
// then read vibe-screenshot.png from the app container's tmp directory
// (the app is sandboxed, so /tmp is not writable):
//
//     ~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/
//
// Renders the window's *presentation* layer tree in-process — no window
// server capture, so it needs no screen-recording permission, works with the
// display asleep or the window occluded, and captures in-flight Core
// Animation (e.g. the artwork cross-fade) mid-animation. Metal content (the
// About window) does not render this way.
void VibeInstallDebugScreenshotHook(void);

// Debug command channel: the Vibe binary doubles as its own CLI client.
//
//     .../Vibe.app/Contents/MacOS/Vibe --debug-cmd dump_state
//     .../Vibe.app/Contents/MacOS/Vibe --debug-cmd set_pitch -4.5
//
// Transport: the client writes a JSON command file ({"id", "args": [verb,
// arg, ...]} — args stay an array end to end, never joined and re-tokenized,
// so quoted paths with any whitespace survive byte-exact) into the sandbox
// container's tmp (the direct-exec'd client runs in the SAME container, so no
// permission is needed), pokes the running app with a darwin notification —
// the payload can't ride the notification itself, since darwin notifications
// carry none and a sandboxed process may not post distributed notifications
// with userInfo — then polls for a per-command response file and prints it.
//
// The command set covers inspection dumps (dump_*), transport/UI actions,
// opening files, and per-file waveform-cache control. The authoritative list
// is VibeDebugCommandTable in DebugUtil.m — one entry per verb carrying its
// usage string, per-verb client wait, and handler; dispatch and the
// unknown-command reply derive from it. Usage docs live in
// .claude/skills/vibe-debug/SKILL.md.

// App side; call at launch. Listens on com.vibe.debug.command (main queue).
void VibeInstallDebugCommandHook(void);

// Core of the `scan_bpm` debug command: decodes the file and runs
// AudioBPMAnalyzer in the calling process, returning one JSON object
// ({"ok","bpm"} — bpm 0 = no confident tempo — or {"error"}). Pure
// decode+analyze with no app state, so the CLI client executes this verb
// locally (`Vibe --debug-cmd scan_bpm <file>` works with no app running and
// never touches a running instance); the command-table entry runs the same
// function app-side for callers that post the command file directly. Sandbox
// caveat: the running process can only read paths it's been granted — the
// direct-exec'd client is limited to the app container, so get-bpm.sh copies
// the file into the container tmp first. Implemented in DebugBPMScan.mm
// (needs the C++ waveform mono-mix header, which DebugUtil.m must not
// import).
NSString *VibeDebugBPMScanJSON(NSString *rawPath);

// Client side; invoked by main() for `Vibe --debug-cmd ...` before
// NSApplicationMain, so no second app instance ever starts. Returns the
// process exit code (0 ok, 1 no response, 2 command error, 64 usage).
int VibeDebugCommandClientMain(int argc, const char *argv[]);

#ifdef __cplusplus
}
#endif

#endif

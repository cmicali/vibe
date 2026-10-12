//
//  VibeWorkTally.h
//  Vibe
//
//  A named counting window over the prefix header's signpost sites: every
//  interval that closes while a window is open is tallied by name, so "the
//  rotation stutters" becomes a count and a total. Instruments answers "which
//  work landed in the dropped frame"; this answers "how much of it ran at all",
//  the number worth diffing across a change and the only one reachable over
//  `devicectl ... --console` with no Instruments attached.
//
//  Begin, Add and End are also declared in Vibe-Prefix.pch, so call sites
//  reach them through its macros without importing a debug header.
//

#import <Foundation/Foundation.h>

#if DEBUG

__BEGIN_DECLS

// Opens a window under `label`, discarding the previous one's counts. A window
// left open keeps counting; nothing is stranded.
void VibeWorkTallyBeginWindow(const char *label);

// One closed interval; `nanos` of 0 is a pure count. Any queue.
void VibeWorkTallyAdd(const char *name, uint64_t nanos);

// Logs the table, slowest total first, and closes the window. A no-op with no
// window open, so a second call cannot double-log.
void VibeWorkTallyEndWindow(void);

// Closes the same window and returns its measurements instead of logging them.
NSDictionary *VibeWorkTallyTakeWindow(void);

__END_DECLS

#endif

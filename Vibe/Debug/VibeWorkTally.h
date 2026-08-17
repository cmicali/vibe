//
//  VibeWorkTally.h
//  Vibe
//
//  A named counting window over the signpost call sites in the prefix header.
//  Every interval that closes while a window is open is tallied by name, and
//  closing the window logs the table — so "the rotation stutters" becomes a
//  count and a total: how many times the waveform's geometry was rebuilt for
//  one rotation, and how many milliseconds of the main thread that took.
//
//  It exists BESIDE the signposts rather than instead of them. Instruments
//  answers "which work landed in the dropped frame"; this answers "how much of
//  it ran at all", which is the number worth diffing across a change and the
//  only one reachable over `devicectl device process launch --console` with no
//  Instruments attached (see the vibe-debug skill's real-device section).
//
//  The three functions are DECLARED in Vibe-Prefix.pch, not here, so that call
//  sites reach them through the VibeSignpost* / VibeWorkTally* macros without
//  importing a debug header. This header is the documentation and the guard.
//

#import <Foundation/Foundation.h>

#if DEBUG

__BEGIN_DECLS

// Opens a window under `label` and discards whatever the previous one held. A
// window left open simply keeps counting; nothing is stranded by a transition
// that never completes.
void VibeWorkTallyBeginWindow(const char *label);

// One closed interval. `nanos` of 0 is a pure count (VibeSignpostCount /
// VibeTallyCount).
// Callable from any queue.
void VibeWorkTallyAdd(const char *name, uint64_t nanos);

// Logs the table, slowest total first, and closes the window. A no-op when no
// window is open, so the tail timer that usually calls it cannot double-log.
void VibeWorkTallyEndWindow(void);

__END_DECLS

#endif

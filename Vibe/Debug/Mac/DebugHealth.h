//
// Created by Christopher Micali on 8/14/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

#if DEBUG

@class MainPlayerController;

// The macOS side of the `dump_health` and `check_invariants` oracles. They
// exist for the stress driver, which cannot tell a healthy hour-long soak from
// a leaking one by screenshotting it: dump_health gives it numbers to diff
// across a run, check_invariants gives it a verdict at a single instant.
//
// Split out of DebugUtil.m only for size; the command-table entries there are
// one line each.

// Process and UI resource counts: memory footprint, threads, file
// descriptors, mach ports, window/view/layer counts, and the player's
// attached engine nodes. Every field is a number the driver diffs between
// iteration N and iteration N+k — none of them is meaningful in isolation.
//
// It reads the engine node count through the player's own serial queue, so a
// wedged player queue makes this command time out. That is deliberate: the
// command channel runs on the main thread and would otherwise never notice.
NSString *VibeDebugHealthJSON(MainPlayerController *controller);

// The macOS-only half of `check_invariants` — the rendered header labels, the
// pitch fader, the table's row count and the scaled tick rate. The verb itself
// is shared (Debug/DebugCommonVerbs.m): it runs
// VibeDebugAppendSharedInvariants first and reaches this through the surface
// protocol's optional debugAppendPlatformInvariants: hook, which
// MainPlayerController implements. Main thread only; returns how many checks
// it ran. See Debug/DebugInvariants.h for the render-lag caveat.
NSUInteger VibeDebugAppendMacInvariants(NSMutableArray<NSDictionary *> *violations,
                                        MainPlayerController *controller);

// Closes the current file and then polls, without ever blocking the main
// thread, until every pending-work counter reads zero — or until a deadline.
// completion runs on the main thread with the reply JSON, so the command
// handler returns nil and lets the channel's async path deliver it.
//
// It exists because a health sample taken mid-flight is nearly useless for
// leak detection: the footprint swings by hundreds of megabytes across a
// decode, which forces the growth limits so wide that a slow leak hides
// inside them. Sampled after a quiesce instead, the app is back at a fixed
// resting state every time, and anything that did not return to it is a leak.
void VibeDebugQuiesce(MainPlayerController *controller, void (^completion)(NSString *responseJSON));

#endif

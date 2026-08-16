//
// Created by Christopher Micali on 8/10/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

#if DEBUG

// The debug command channel's wire format: the transport's notification name,
// the per-command file paths, and the JSON reply serialization. Every end of
// the channel agrees here — both apps' command tables, the shared verbs and
// dispatch, and the mac CLI client — which is why it is neither app's to own.
// Same C-linkage guard rationale as Mac/DebugUtil.h.
//
// Named for what it holds, not for who shares it: "shared" already means
// mac-and-iOS everywhere else in this tree (see the root CLAUDE.md on the
// directory being the platform boundary), and this file predates that meaning.

#ifdef __cplusplus
extern "C" {
#endif

extern NSString *const kVibeDebugCommandNotification;

NSString *VibeDebugTmpPath(NSString *name);
NSString *VibeDebugCommandPath(NSString *commandId);
NSString *VibeDebugResponsePath(NSString *commandId);
NSString *VibeDebugScreenshotPathForCommand(NSString *commandId);

NSString *VibeJSONString(NSDictionary *dict);
NSString *VibeErrorJSON(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

BOOL VibeParseDouble(NSString *token, double *out);

// The command table's per-verb spec — {usage, clientTimeout, handler} —
// defined in DebugUtil.m. The client reads clientTimeout from it, so its
// per-verb wait derives from the same table the app dispatches with.
NSDictionary *VibeCommandSpecForVerb(NSString *verb);

#ifdef __cplusplus
}
#endif

#endif

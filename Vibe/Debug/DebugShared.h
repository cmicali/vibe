//
// Created by Christopher Micali on 8/10/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

#if DEBUG

// Shared between the app side of the debug command channel (DebugUtil.m) and
// the CLI client (DebugClient.m): the transport's notification name, the
// per-command file paths, and the JSON reply serialization. Same C-linkage
// guard rationale as DebugUtil.h.

#ifdef __cplusplus
extern "C" {
#endif

extern NSString *const kVibeDebugCommandNotification;

NSString *VibeDebugTmpPath(NSString *name);
NSString *VibeDebugCommandPath(NSString *commandId);
NSString *VibeDebugResponsePath(NSString *commandId);
NSString *VibeDebugScreenshotPathForCommand(NSString *commandId);

NSString *VibeJSONString(NSDictionary *dict);

BOOL VibeParseDouble(NSString *token, double *out);

// The command table's per-verb spec — {usage, clientTimeout, handler} —
// defined in DebugUtil.m. The client reads clientTimeout from it, so its
// per-verb wait derives from the same table the app dispatches with.
NSDictionary *VibeCommandSpecForVerb(NSString *verb);

#ifdef __cplusplus
}
#endif

#endif

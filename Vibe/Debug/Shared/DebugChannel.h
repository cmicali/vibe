//
// Created by Christopher Micali on 8/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

#if DEBUG

NS_ASSUME_NONNULL_BEGIN

// The platform-neutral half of the debug command channel: the command-file
// drain, payload validation, response writing, the stale-file sweep, and the
// wake-up listeners. The platform command tables — DebugUtil.m on macOS,
// Vibe/iOS/DebugCommands.m on iOS — supply the executor and own every verb.
//
// Same C-linkage guard rationale as DebugUtil.h.

#ifdef __cplusplus
extern "C" {
#endif

// Runs one parsed command. args[0] is the verb; the rest are its arguments,
// one token per client argv entry, never re-tokenized. Returns the JSON reply
// to write, or nil when the command completes asynchronously and writes its
// own reply later through VibeWriteDebugResponse.
typedef NSString * _Nullable (^VibeDebugChannelExecutor)(NSArray<NSString *> *args,
                                                         NSString *commandId);

// Installs the channel: sweeps files orphaned by earlier runs, then listens on
// com.vibe.debug.command, on the main queue. On iOS it also watches the
// container tmp directory itself, because the simulator host can write command
// files straight into it but a host-side notifyutil posts into the mac's
// notification namespace, not the simulator's.
void VibeInstallDebugCommandChannel(VibeDebugChannelExecutor executor);

// Writes the per-command response file the client polls for. Both the
// synchronous path and commands that finish asynchronously from their own
// completion block use it.
void VibeWriteDebugResponse(NSString *commandId, NSString *response);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif

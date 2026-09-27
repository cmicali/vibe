//
//  DebugChannel.h
//  Vibe
//

#import <Foundation/Foundation.h>

#if DEBUG

NS_ASSUME_NONNULL_BEGIN

// The platform-neutral half of the debug command channel: the command-file
// drain, payload validation, response writing, the stale-file sweep and the
// wake-up listeners. The platform tables (Mac/DebugCommandTable.m,
// iOS/DebugCommands.m) supply the executor and own every verb.

#ifdef __cplusplus
extern "C" {
#endif

// Runs one parsed command. args[0] is the verb; the rest are its arguments,
// one token per client argv entry, never re-tokenized. Returns the JSON reply
// to write, or nil when the command completes asynchronously and writes its
// own reply later through VibeWriteDebugResponse.
typedef NSString * _Nullable (^VibeDebugChannelExecutor)(NSArray<NSString *> *args,
                                                         NSString *commandId);

// Sweeps files orphaned by earlier runs, then listens on
// kVibeDebugCommandNotification on the main queue. On iOS it also watches the
// container's tmp directory: the host writes command files straight into it,
// but a host-side notifyutil posts into the mac's namespace, not the
// simulator's.
void VibeInstallDebugCommandChannel(VibeDebugChannelExecutor executor);

// Writes the per-command response file the client polls for; asynchronous
// commands call it from their own completion.
void VibeWriteDebugResponse(NSString *commandId, NSString *response);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif

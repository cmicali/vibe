//
//  DebugCommandDispatch.h
//  Vibe
//
//  The command table's shape and the lookup over it — the half of dispatch
//  that knows nothing about either platform. Both tables are arrays of these
//  specs, so one verb lookup and one unknown-command reply serve both.
//
//  It deliberately does NOT invoke a handler. Each platform's table is typed
//  to its own controller, and calling it belongs where that type is known;
//  what is common is finding the spec and answering when there is none.
//

#if DEBUG

#import <Foundation/Foundation.h>
#import "DebugPlayerSurface.h"

NS_ASSUME_NONNULL_BEGIN

// A cross-platform verb's handler. Returns the JSON reply to write, or nil
// when the command replies asynchronously through VibeWriteDebugResponse.
typedef NSString *_Nullable (^VibeDebugSurfaceHandler)(NSArray<NSString *> *tokens,
                                                       NSString *commandId,
                                                       id<VibeDebugPlayerSurface> surface);

// Builds a spec. clientTimeout is how long the CLI client waits for this
// verb's reply, in seconds, where 0 means the default.
NSDictionary *VibeDebugCmd(NSString *usage, NSTimeInterval clientTimeout,
                           VibeDebugSurfaceHandler handler);

// Marks a spec whose verb writes AppSettings, and the query the platform
// funnels read back. Declarative so a new store-writing verb cannot forget
// its platform's post-write follow-up: the mac funnel refreshes the visible
// settings pane after the handler, so a dump_settings_ui right after reads
// what the verb wrote; iOS has no settings walker and ignores the flag.
NSDictionary *VibeDebugWritesSettings(NSDictionary *spec);
BOOL VibeDebugSpecWritesSettings(NSDictionary *spec);

// The first word of a usage string, which is the verb itself.
NSString *VibeDebugVerbFromUsage(NSString *usage);

// The spec for verb in table, or nil.
NSDictionary *_Nullable VibeDebugSpecForVerb(NSArray<NSDictionary *> *table, NSString *verb);

// The unknown-command reply, which is the channel's authoritative command
// list. tables are walked in order; extraUsages carries verbs that never reach
// a table — the ones the CLI client runs in its own process.
NSString *VibeDebugUnknownCommandReply(NSString *verb,
                                       NSArray<NSArray<NSDictionary *> *> *tables,
                                       NSArray<NSString *> *_Nullable extraUsages);

// ---- The token contract, shared by every verb that takes arguments.
//
// tokens[0] is the verb and the rest are its arguments: one token per CLI argv
// entry, transported verbatim and never re-tokenized.

// The arguments rejoined with single spaces, as a convenience so that an
// unquoted multi-word title still works. A properly quoted argument arrives as
// one token and passes through exactly, consecutive spaces and all.
NSString *VibeRestArgument(NSArray<NSString *> *tokens);

// The same, with a leading ~ expanded.
NSString *VibePathArgument(NSArray<NSString *> *tokens);

// Shared validation for the verbs that take one existing-file argument, so
// their argument contracts cannot drift. Returns the path, or nil with
// *errorJSON set to the reply to send; errorJSON is written unchecked, so it
// is required.
NSString *_Nullable VibeExistingFileArgument(NSArray<NSString *> *tokens,
                                             NSString *_Nullable *_Nonnull errorJSON);

NS_ASSUME_NONNULL_END

#endif

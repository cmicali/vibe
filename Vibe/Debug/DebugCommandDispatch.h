//
//  DebugCommandDispatch.h
//  Vibe
//
//  The command table's shape and the lookup over it — the half of dispatch
//  that knows nothing about either platform. Both tables are arrays of these
//  specs, so one verb lookup and one unknown-command reply serve both.
//
//  It deliberately does NOT invoke a handler. Each platform's dispatcher
//  supplies its own controller, and the call belongs where that is known;
//  what is common is finding the spec and answering when there is none.
//

#if DEBUG

#import <Foundation/Foundation.h>
#import "DebugPlayerSurface.h"

NS_ASSUME_NONNULL_BEGIN

// A verb's handler. Returns the JSON reply to write, or nil when the command
// replies asynchronously through VibeWriteDebugResponse. controller is typed
// id because each table names its own — id<VibeDebugPlayerSurface> for the
// shared verbs, the shell's controller class for a platform's — and a block
// literal keeps its parameter type, so the body is still checked against what
// it reads; only the table's slot is untyped. Never nil: each dispatcher
// answers "app not fully launched" before any handler runs.
typedef NSString *_Nullable (^VibeDebugCommandHandler)(NSArray<NSString *> *tokens,
                                                       NSString *commandId,
                                                       id controller);

// Builds a spec. clientTimeout is how long the CLI client waits for this
// verb's reply, in seconds, where 0 means the default.
NSDictionary *VibeDebugCmd(NSString *usage, NSTimeInterval clientTimeout,
                           VibeDebugCommandHandler handler);

// A transport or toggle verb: runs action against the controller, then replies
// with the surface's compact action summary, so every one of them answers in
// the same shape. Both shells' controllers adopt VibeDebugPlayerSurface.
NSDictionary *VibeTransportCmd(NSString *usage, void (^action)(id controller));

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

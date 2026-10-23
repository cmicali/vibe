//
//  DebugCommandDispatch.h
//  vibe-libs
//
//  The command table's shape and the lookup over it, so one verb lookup and
//  one unknown-command reply serve every table. It never invokes a handler:
//  the app's dispatcher supplies its own controller, and the call belongs
//  where that is known.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Returns the JSON reply, or nil when the command replies asynchronously
// through VibeWriteDebugResponse. controller is id because each table names
// its own type; a block literal keeps its parameter type, so the body is
// still checked. Never nil: the dispatcher answers an error first when the
// app has no controller yet.
typedef NSString *_Nullable (^VibeDebugCommandHandler)(NSArray<NSString *> *tokens,
                                                       NSString *commandId,
                                                       id controller);

// Builds a spec. clientTimeout is how long the CLI client waits for this
// verb's reply, in seconds, where 0 means the default.
NSDictionary *VibeDebugCmd(NSString *usage, NSTimeInterval clientTimeout,
                           VibeDebugCommandHandler handler);

NSString *VibeDebugVerbFromUsage(NSString *usage);

// The spec for verb in table, or nil.
NSDictionary *_Nullable VibeDebugSpecForVerb(NSArray<NSDictionary *> *table, NSString *verb);

// The unknown-command reply, which is the channel's authoritative command
// list. extraUsages carries the verbs the CLI client runs in its own process.
NSString *VibeDebugUnknownCommandReply(NSString *verb,
                                       NSArray<NSArray<NSDictionary *> *> *tables,
                                       NSArray<NSString *> *_Nullable extraUsages);

// tokens[0] is the verb and the rest its arguments: one token per CLI argv
// entry, never re-tokenized.

// The arguments rejoined with single spaces, so an unquoted multi-word title
// still works; a quoted argument passes through exactly.
NSString *VibeRestArgument(NSArray<NSString *> *tokens);

// VibeRestArgument with a leading ~ expanded.
NSString *VibePathArgument(NSArray<NSString *> *tokens);

// The <on|off> argument every settings switch verb takes; NO for anything else.
BOOL VibeParseOnOff(NSArray<NSString *> *tokens, BOOL *on);

// For verbs taking one existing-file argument, so their contracts cannot
// drift. Returns the path, or nil with *errorJSON set to the reply; errorJSON
// is written unchecked, so it is required.
NSString *_Nullable VibeExistingFileArgument(NSArray<NSString *> *tokens,
                                             NSString *_Nullable *_Nonnull errorJSON);

NS_ASSUME_NONNULL_END

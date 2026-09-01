//
//  DebugCommandDispatch.m
//  Vibe
//
//  See DebugCommandDispatch.h.
//

#import "DebugCommandDispatch.h"

#if DEBUG

#import "DebugWireFormat.h"

NSDictionary *VibeDebugCmd(NSString *usage, NSTimeInterval clientTimeout,
                           VibeDebugSurfaceHandler handler) {
    return @{@"usage": usage, @"clientTimeout": @(clientTimeout), @"handler": [handler copy]};
}

static NSString *const kVibeDebugWritesSettingsKey = @"writesSettings";

NSDictionary *VibeDebugWritesSettings(NSDictionary *spec) {
    NSMutableDictionary *marked = [spec mutableCopy];
    marked[kVibeDebugWritesSettingsKey] = @YES;
    return marked;
}

BOOL VibeDebugSpecWritesSettings(NSDictionary *spec) {
    return [spec[kVibeDebugWritesSettingsKey] boolValue];
}

NSString *VibeDebugVerbFromUsage(NSString *usage) {
    NSRange space = [usage rangeOfString:@" "];
    return space.location == NSNotFound ? usage : [usage substringToIndex:space.location];
}

NSDictionary *VibeDebugSpecForVerb(NSArray<NSDictionary *> *table, NSString *verb) {
    for (NSDictionary *spec in table) {
        if ([VibeDebugVerbFromUsage(spec[@"usage"]) isEqualToString:verb]) {
            return spec;
        }
    }
    return nil;
}

NSString *VibeDebugUnknownCommandReply(NSString *verb,
                                       NSArray<NSArray<NSDictionary *> *> *tables,
                                       NSArray<NSString *> *extraUsages) {
    NSMutableArray<NSString *> *usages = [NSMutableArray array];
    for (NSArray<NSDictionary *> *table in tables) {
        for (NSDictionary *spec in table) {
            [usages addObject:spec[@"usage"]];
        }
    }
    [usages addObjectsFromArray:extraUsages ?: @[]];
    return VibeErrorJSON(@"unknown command '%@'. Commands: %@",
                         verb, [usages componentsJoinedByString:@", "]);
}

// tokens[0] is the verb and the rest are its arguments: one token per CLI argv
// entry, transported verbatim and never re-tokenized. They are rejoined with
// single spaces as a convenience, so that an unquoted multi-word title still
// works. A properly quoted argument arrives as one token and passes through
// exactly, consecutive spaces and all.
NSString *VibeRestArgument(NSArray<NSString *> *tokens) {
    // An empty array would make the length below (NSUInteger)-1 and trap. Every
    // caller has a verb in hand, so this is the precondition rather than a case.
    if (tokens.count < 2) {
        return @"";
    }
    return [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]
            componentsJoinedByString:@" "];
}

// A path argument: the rest of the tokens, with a leading ~ expanded.
NSString *VibePathArgument(NSArray<NSString *> *tokens) {
    return VibeRestArgument(tokens).stringByExpandingTildeInPath;
}

// Shared validation for the verbs that take one existing-file argument, which
// keeps file_cache's and file_clear_cache's argument contracts identical. It
// returns the path, or nil with *errorJSON set to the reply to send.
NSString *VibeExistingFileArgument(NSArray<NSString *> *tokens, NSString **errorJSON) {
    NSString *verb = tokens.firstObject;
    if (tokens.count < 2) {
        *errorJSON = VibeErrorJSON(@"usage: %@ <file>", verb);
        return nil;
    }
    NSString *path = VibePathArgument(tokens);
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) {
        *errorJSON = VibeErrorJSON(@"%@ expects an existing file: '%@'", verb, path);
        return nil;
    }
    return path;
}

#endif

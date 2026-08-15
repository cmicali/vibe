//
// Created by Christopher Micali on 8/10/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "DebugShared.h"

#if DEBUG

NSString *const kVibeDebugCommandNotification = @"com.vibe.debug.command";

NSString *VibeDebugTmpPath(NSString *name) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

// Per-command files, as on the response side. One fixed command path loses a
// command when two clients write back to back, because the second write
// replaces the first before the app reads it.
NSString *VibeDebugCommandPath(NSString *commandId) {
    return VibeDebugTmpPath([NSString stringWithFormat:@"vibe-command-%@.json", commandId]);
}

NSString *VibeDebugResponsePath(NSString *commandId) {
    return VibeDebugTmpPath([NSString stringWithFormat:@"vibe-response-%@.txt", commandId]);
}

NSString *VibeDebugScreenshotPathForCommand(NSString *commandId) {
    return VibeDebugTmpPath([NSString stringWithFormat:@"vibe-screenshot-%@.png", commandId]);
}

// Every debug command replies with exactly one JSON object. An error is
// {"error": "..."}, which the client maps to exit code 2.
NSString *VibeJSONString(NSDictionary *dict) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    return json ?: @"{\"error\": \"response not JSON-serializable\"}";
}

NSString *VibeErrorJSON(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return VibeJSONString(@{@"error": message});
}

BOOL VibeParseDouble(NSString *token, double *out) {
    NSScanner *scanner = [NSScanner scannerWithString:token];
    return [scanner scanDouble:out] && scanner.isAtEnd;
}

#endif

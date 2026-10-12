//
//  DebugWireFormat.m
//  Vibe
//

#import "DebugWireFormat.h"

#if DEBUG

NSString *const kVibeDebugCommandNotification = @"com.vibe.debug.command";

NSString *VibeDebugTmpPath(NSString *name) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

// Per-command, like the response: one fixed command path loses a command when
// two clients write back to back.
NSString *VibeDebugCommandPath(NSString *commandId) {
    return VibeDebugTmpPath([NSString stringWithFormat:@"vibe-command-%@.json", commandId]);
}

NSString *VibeDebugResponsePath(NSString *commandId) {
    return VibeDebugTmpPath([NSString stringWithFormat:@"vibe-response-%@.txt", commandId]);
}

NSString *VibeDebugScreenshotPathForCommand(NSString *commandId) {
    return VibeDebugTmpPath([NSString stringWithFormat:@"vibe-screenshot-%@.png", commandId]);
}

// Every reply is one JSON object; {"error": ...} maps to client exit code 2.
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

BOOL VibeParseByteCount(NSString *token, uint64_t *bytes) {
    double scale = [token hasSuffix:@"K"] ? 1024 : [token hasSuffix:@"M"] ? 1024 * 1024 : 1;
    NSString *digits = scale > 1 ? [token substringToIndex:token.length - 1] : token;
    double number = 0;
    if (!VibeParseDouble(digits, &number) || number < 0) {
        return NO;
    }
    *bytes = (uint64_t)(number * scale);
    return YES;
}

BOOL VibeParseNonnegativeInteger(NSString *token, NSUInteger *out) {
    if (!token.length) {
        return NO;
    }
    NSUInteger parsed = 0;
    for (NSUInteger index = 0; index < token.length; index++) {
        unichar character = [token characterAtIndex:index];
        if (character < '0' || character > '9') {
            return NO;
        }
        NSUInteger digit = character - '0';
        if (parsed > (NSUIntegerMax - digit) / 10) {
            return NO;
        }
        parsed = parsed * 10 + digit;
    }
    *out = parsed;
    return YES;
}

#endif

//
//  HTTPTransferRules.h
//  Vibe
//
//  The HTTP transfer's decisions that need no network: when to resend, and
//  what a response's headers say about the file's size and version.
//  Header-only and Foundation-only, so the macOS suite tests it.
//

#ifndef HTTPTransferRules_h
#define HTTPTransferRules_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A throttled or briefly unavailable request is tried this many times in all.
static const NSInteger kVibeHTTPMaximumAttempts = 4;

// Seconds to wait before retrying, or a negative answer for "do not retry".
// 429 is rate limiting and 503 a transient outage. Retry-After is honored but
// capped, since a waiting download holds a materialization lane.
static inline NSTimeInterval VibeHTTPRetryDelay(NSInteger status, NSString *_Nullable retryAfter) {
    if (status != 429 && status != 503) {
        return -1;
    }
    double seconds = retryAfter.doubleValue;
    if (seconds <= 0) {
        seconds = 1;
    }
    return MIN(seconds, 10.0);
}

// A link that dropped or stalled, which a resend may outlast. Anything else
// (TLS, a malformed response) would only fail again.
static inline BOOL VibeHTTPIsConnectionError(NSError *_Nullable error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) {
        return NO;
    }
    switch (error.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
            return YES;
        default:
            return NO;
    }
}

// A header's decimal count of bytes. -1 for anything but digits, an overflow
// included.
static inline int64_t VibeHTTPParseLength(NSString *_Nullable text) {
    NSString *digits = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (digits.length == 0) {
        return -1;
    }
    int64_t value = 0;
    for (NSUInteger i = 0; i < digits.length; i++) {
        unichar c = [digits characterAtIndex:i];
        if (c < '0' || c > '9' || value > (INT64_MAX - (c - '0')) / 10) {
            return -1;
        }
        value = value * 10 + (c - '0');
    }
    return value;
}

// The total of a Content-Range: "bytes 0-15/4000" and "bytes */4000" are
// 4000. -1 when the total is unknown ("/*"), or the header is absent or
// malformed, a range outside its own total included.
static inline int64_t VibeHTTPContentRangeTotal(NSString *_Nullable contentRange) {
    NSString *text = [contentRange stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (![text.lowercaseString hasPrefix:@"bytes "]) {
        return -1;
    }
    NSString *spec = [[text substringFromIndex:6] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSRange slash = [spec rangeOfString:@"/"];
    if (slash.location == NSNotFound) {
        return -1;
    }
    int64_t total = VibeHTTPParseLength([spec substringFromIndex:NSMaxRange(slash)]);
    NSString *range = [spec substringToIndex:slash.location];
    if (total < 0 || [range isEqualToString:@"*"]) {
        return total;
    }
    NSRange dash = [range rangeOfString:@"-"];
    if (dash.location == NSNotFound) {
        return -1;
    }
    int64_t first = VibeHTTPParseLength([range substringToIndex:dash.location]);
    int64_t last = VibeHTTPParseLength([range substringFromIndex:NSMaxRange(dash)]);
    return first >= 0 && last >= first && last < total ? total : -1;
}

// The whole file's size a response states, -1 when it states none. A 206
// states it as its Content-Range total, a 200 as its Content-Length. Under a
// Content-Encoding the length counts the encoded body, not the file.
static inline int64_t VibeHTTPSizeFromHeaders(NSInteger status,
                                              NSString *_Nullable contentRange,
                                              NSString *_Nullable contentLength,
                                              NSString *_Nullable contentEncoding) {
    if (status == 206) {
        return VibeHTTPContentRangeTotal(contentRange);
    }
    if (status != 200) {
        return -1;
    }
    NSString *encoding = [contentEncoding stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (encoding.length > 0 && [encoding caseInsensitiveCompare:@"identity"] != NSOrderedSame) {
        return -1;
    }
    return VibeHTTPParseLength(contentLength);
}

// What names a response's bytes: a strong ETag, else Last-Modified, nil for
// neither. A weak ETag (W/"…") promises equivalent content, not the same
// bytes, so it counts as absent.
static inline NSString *_Nullable VibeHTTPVersionFromHeaders(NSString *_Nullable etag,
                                                             NSString *_Nullable lastModified) {
    NSString *tag = [etag stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (tag.length > 0 && ![tag hasPrefix:@"W/"]) {
        return tag;
    }
    NSString *modified = [lastModified stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return modified.length > 0 ? modified : nil;
}

NS_ASSUME_NONNULL_END

#endif /* HTTPTransferRules_h */

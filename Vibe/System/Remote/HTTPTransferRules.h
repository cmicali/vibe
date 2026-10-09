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

// A Content-Range's parts: "bytes 0-15/4000" is 0, 15 and 4000, and
// "bytes */4000" has no range, -1 for first and last. A total of "*" is -1.
// NO when the header is absent or malformed, a range outside its own total
// included.
static inline BOOL VibeHTTPParseContentRange(NSString *_Nullable contentRange,
                                             int64_t *first, int64_t *last, int64_t *total) {
    *first = *last = *total = -1;
    NSString *text = [contentRange stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (![text.lowercaseString hasPrefix:@"bytes "]) {
        return NO;
    }
    NSString *spec = [[text substringFromIndex:6] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSRange slash = [spec rangeOfString:@"/"];
    if (slash.location == NSNotFound) {
        return NO;
    }
    NSString *size = [spec substringFromIndex:NSMaxRange(slash)];
    *total = [size isEqualToString:@"*"] ? -1 : VibeHTTPParseLength(size);
    if (*total < 0 && ![size isEqualToString:@"*"]) {
        return NO;
    }
    NSString *range = [spec substringToIndex:slash.location];
    if ([range isEqualToString:@"*"]) {
        return *total >= 0;
    }
    NSRange dash = [range rangeOfString:@"-"];
    if (dash.location == NSNotFound) {
        return NO;
    }
    *first = VibeHTTPParseLength([range substringToIndex:dash.location]);
    *last = VibeHTTPParseLength([range substringFromIndex:NSMaxRange(dash)]);
    return *first >= 0 && *last >= *first && (*total < 0 || *last < *total);
}

// The total of a Content-Range: "bytes 0-15/4000" and "bytes */4000" are
// 4000. -1 when the total is unknown ("/*"), or the header is absent or
// malformed.
static inline int64_t VibeHTTPContentRangeTotal(NSString *_Nullable contentRange) {
    int64_t first, last, total;
    return VibeHTTPParseContentRange(contentRange, &first, &last, &total) ? total : -1;
}

// The first byte a Content-Range carries: "bytes 100-199/4000" is 100. -1 for
// "bytes */4000", which carries none, and for an absent or malformed header.
static inline int64_t VibeHTTPContentRangeStart(NSString *_Nullable contentRange) {
    int64_t first, last, total;
    return VibeHTTPParseContentRange(contentRange, &first, &last, &total) ? first : -1;
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
// neither. A weak ETag (W/"…", in either case) promises equivalent content,
// not the same bytes, so it counts as absent. The one weak-ETag rule.
static inline NSString *_Nullable VibeHTTPVersionFromHeaders(NSString *_Nullable etag,
                                                             NSString *_Nullable lastModified) {
    NSString *tag = [etag stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (tag.length > 0 && ![tag hasPrefix:@"W/"] && ![tag hasPrefix:@"w/"]) {
        return tag;
    }
    NSString *modified = [lastModified stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return modified.length > 0 ? modified : nil;
}

// Whether a response naming another version than the one pinned still
// carries the same file. A CDN's edges can each tag one file with an ETag of
// their own. The same size and the same Last-Modified, both stated, are taken
// as the same file.
static inline BOOL VibeHTTPIsSameFileUnderAnotherETag(int64_t pinnedSize,
                                                      NSString *_Nullable pinnedLastModified,
                                                      int64_t size,
                                                      NSString *_Nullable lastModified) {
    NSCharacterSet *spaces = NSCharacterSet.whitespaceCharacterSet;
    NSString *pinned = [pinnedLastModified stringByTrimmingCharactersInSet:spaces];
    NSString *modified = [lastModified stringByTrimmingCharactersInSet:spaces];
    return pinnedSize >= 0 && size == pinnedSize && pinned.length > 0 && [modified isEqualToString:pinned];
}

NS_ASSUME_NONNULL_END

#endif /* HTTPTransferRules_h */

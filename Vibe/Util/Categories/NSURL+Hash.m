//
//  NSURL+Hash.m
//  Vibe
//

#import "NSURL+Hash.h"
#include <CommonCrypto/CommonDigest.h>

@implementation NSURL (Hash)

- (nullable NSString *)cacheKey {
    // Resolve symlinks first: attributesOfItemAtPath: does NOT traverse them,
    // so a symlinked track would key off the link's own tiny, fixed size/mtime
    // — retagging the target file would keep serving stale cached metadata
    // for up to the cache age limit. Keying off the resolved path also lets a
    // link and its target share one cache entry (same underlying file).
    NSString *path = [self.path stringByResolvingSymlinksInPath];
    NSError *error = nil;
    NSDictionary<NSFileAttributeKey, id> *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error];
    if (!attrs) {
        // No key rather than a degenerate "0-0-<sha1>" one: callers memoize
        // and persist under this, and a transiently-unstattable file would
        // mis-file its cache entries under that garbage identity forever.
        LogWarn(@"Could not stat %@ for cache key: %@", path, error);
        return nil;
    }
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    // Microsecond resolution is enough to distinguish writes; APFS only
    // surfaces sub-second mtime via getattrlist anyway.
    long long mtimeUs = (long long)llround([(NSDate *)attrs[NSFileModificationDate] timeIntervalSince1970] * 1e6);

    const char *pathCStr = [path UTF8String];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(pathCStr, (CC_LONG)strlen(pathCStr), digest);
    char hex[2 * CC_SHA1_DIGEST_LENGTH + 1];
    for (size_t i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        snprintf(hex + 2 * i, 3, "%02x", digest[i]);
    }
    return [NSString stringWithFormat:@"%llu-%lld-%s", size, mtimeUs, hex];
}

@end

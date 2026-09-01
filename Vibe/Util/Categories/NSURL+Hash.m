//
//  NSURL+Hash.m
//  Vibe
//

#import "NSURL+Hash.h"
#include <CommonCrypto/CommonDigest.h>

@implementation NSData (Hash)

// Hexed in a stack buffer: this runs once per track on the scan workers,
// where twenty appendFormat: calls per key add up across a large folder.
- (NSString *)sha1Hex {
    static const char kHexDigits[] = "0123456789abcdef";
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(self.bytes, (CC_LONG)self.length, digest);
    char hex[CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        hex[i * 2] = kHexDigits[digest[i] >> 4];
        hex[i * 2 + 1] = kHexDigits[digest[i] & 0x0F];
    }
    return [[NSString alloc] initWithBytes:hex length:sizeof(hex) encoding:NSASCIIStringEncoding];
}

@end

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

    NSString *hex = [[path dataUsingEncoding:NSUTF8StringEncoding] sha1Hex];
    return [NSString stringWithFormat:@"%llu-%lld-%@", size, mtimeUs, hex];
}

@end

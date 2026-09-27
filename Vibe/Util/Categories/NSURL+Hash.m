//
//  NSURL+Hash.m
//  Vibe
//

#import "NSURL+Hash.h"
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>

@implementation NSData (Hash)

// A stack buffer: this runs once per track on the scan workers.
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

- (nullable NSString *)pathKey {
    NSString *path = self.URLByStandardizingPath.path;
    if (!path) {
        return nil;
    }
    NSString *home = NSHomeDirectory().stringByStandardizingPath;
    if ([path hasPrefix:[home stringByAppendingString:@"/"]]) {
        path = [@"~" stringByAppendingString:[path substringFromIndex:home.length]];
    }
    return [[path dataUsingEncoding:NSUTF8StringEncoding] sha1Hex];
}

- (nullable NSString *)cacheKey {
    // A link and its target share one entry, so retagging the target
    // invalidates it.
    NSString *path = [self.path stringByResolvingSymlinksInPath];
    // stat(2), not attributesOfItemAtPath:, whose attribute fetch was the
    // scan's largest cost.
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) {
        // Not "0-0-<sha1>": a transiently unstattable file would persist
        // entries under that identity forever.
        LogWarn(@"Could not stat %@ for cache key: %s", path, strerror(errno));
        return nil;
    }
    // TRAP: round exactly as Foundation's NSDate for this timespec does —
    // reference-date seconds BEFORE the nanoseconds — or persisted keys
    // change: direct 1970 arithmetic lands 1µs off on ~6% of real files.
    NSTimeInterval sinceReference = ((NSTimeInterval)st.st_mtimespec.tv_sec - NSTimeIntervalSince1970)
            + (NSTimeInterval)st.st_mtimespec.tv_nsec / 1e9;
    NSDate *modified = [NSDate dateWithTimeIntervalSinceReferenceDate:sinceReference];
    long long mtimeUs = (long long)llround(modified.timeIntervalSince1970 * 1e6);

    NSString *hex = [[path dataUsingEncoding:NSUTF8StringEncoding] sha1Hex];
    return [NSString stringWithFormat:@"%llu-%lld-%@", (unsigned long long)st.st_size, mtimeUs, hex];
}

@end

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
    // Resolve symlinks first, so that the hashed path is the target's: a link
    // and its target then share one entry, and retagging the target
    // invalidates it rather than serving stale metadata through the link.
    NSString *path = [self.path stringByResolvingSymlinksInPath];
    // stat(2), not NSFileManager's attributesOfItemAtPath:, which fetches every
    // extended attribute of the file to build a dictionary two fields are read
    // from — that fetch was the single largest cost of the playlist scan.
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) {
        // No key rather than a degenerate "0-0-<sha1>" one: callers memoize
        // and persist under this, and a transiently-unstattable file would
        // mis-file its cache entries under that garbage identity forever.
        LogWarn(@"Could not stat %@ for cache key: %s", path, strerror(errno));
        return nil;
    }
    // Microsecond resolution is enough to distinguish writes; APFS only
    // surfaces sub-second mtime via getattrlist anyway.
    //
    // TRAP: the rounding must match what Foundation's NSDate for this timespec
    // produced, or every persisted key changes. Foundation converts to
    // reference-date seconds BEFORE adding the nanoseconds; doing the 1970
    // arithmetic directly lands 1µs off on about 6% of real files, which
    // would orphan their cache entries.
    NSTimeInterval sinceReference = ((NSTimeInterval)st.st_mtimespec.tv_sec - NSTimeIntervalSince1970)
            + (NSTimeInterval)st.st_mtimespec.tv_nsec / 1e9;
    NSDate *modified = [NSDate dateWithTimeIntervalSinceReferenceDate:sinceReference];
    long long mtimeUs = (long long)llround(modified.timeIntervalSince1970 * 1e6);

    NSString *hex = [[path dataUsingEncoding:NSUTF8StringEncoding] sha1Hex];
    return [NSString stringWithFormat:@"%llu-%lld-%@", (unsigned long long)st.st_size, mtimeUs, hex];
}

@end

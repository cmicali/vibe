//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSURL+Hash.h"
#include <CommonCrypto/CommonDigest.h>

@implementation NSURL (Hash)

- (NSString *)cacheKey {
    // Resolve symlinks first: attributesOfItemAtPath: does NOT traverse them,
    // so a symlinked track would key off the link's own tiny, fixed size/mtime
    // — retagging the target file would keep serving stale cached metadata
    // for up to the cache age limit. Keying off the resolved path also lets a
    // link and its target share one cache entry (same underlying file).
    NSString *path = [self.path stringByResolvingSymlinksInPath];
    NSDictionary<NSFileAttributeKey, id> *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
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

//
//  PINCache+VibeAudioCache.m
//  Vibe
//

#import "PINCache+VibeAudioCache.h"

// The per-cache disk budget. A metadata archive is roughly 5-20KB and a
// waveform 64KB, but each art-bearing track also carries a display-art sidecar
// of up to ~60KB, so the budget is sized for around ten thousand such tracks
// before LRU eviction starts.
static const NSUInteger kAudioCacheByteLimit = 512 * 1024 * 1024;

// Entries untouched for this long are evicted. A rewritten or moved file leaves
// an orphaned entry whose size-and-mtime key never matches again, and that must
// not sit in the byte budget forever.
static const NSTimeInterval kAudioCacheAgeLimit = 6 * (30 * (24 * 60 * 60)); // 6 months

@implementation PINCache (VibeAudioCache)

+ (PINCache *)audioCacheWithName:(NSString *)name {
    PINCache *cache = [[PINCache alloc] initWithName:name];
    cache.diskCache.byteLimit = kAudioCacheByteLimit;
    cache.diskCache.ageLimit = kAudioCacheAgeLimit;
    return cache;
}

- (void)audioDiskUsageWithCompletion:(void (^)(NSUInteger fileCount,
                                               unsigned long long totalBytes))completion {
    __block NSUInteger count = 0;
    __block unsigned long long bytes = 0;
    [self.diskCache enumerateObjectsWithBlock:^(NSString *key, NSURL *fileURL, BOOL *stop) {
        count++;
        NSNumber *size = nil;
        if ([fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil]) {
            bytes += size.unsignedLongLongValue;
        }
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(count, bytes);
    });
}

@end

//
//  PINCache+VibeAudioCache.m
//  Vibe
//

#import "PINCache+VibeAudioCache.h"

// Per cache, about ten thousand tracks before LRU eviction: a waveform is
// 128 KB, a metadata archive 5–20 KB plus up to ~60 KB of display art.
static const NSUInteger kAudioCacheByteLimit = 1024 * 1024 * 1024;

// A rewritten or moved file orphans its entry (the key never matches again),
// so untouched entries age out rather than hold the byte budget forever.
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
    run_on_main_thread({
        completion(count, bytes);
    });
}

@end

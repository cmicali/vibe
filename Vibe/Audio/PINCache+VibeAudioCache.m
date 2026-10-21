//
//  PINCache+VibeAudioCache.m
//  Vibe
//

#import "PINCache+VibeAudioCache.h"
#import "HelperMacros.h"

// Each store has its own budget. A waveform entry grows with its track, about
// 50 KiB a minute and double that with bands. Metadata and display-art sizes
// depend on the file.
static const NSUInteger kAudioCacheByteLimit = 1024 * 1024 * 1024;

// Changed file identities can orphan entries. Untouched entries age out
// instead of holding the byte budget forever.
static const NSTimeInterval kAudioCacheAgeLimit = 6 * (30 * (24 * 60 * 60)); // 180 days

@implementation PINCache (VibeAudioCache)

+ (PINCache *)audioCacheWithName:(NSString *)name rootPath:(NSString *)rootPath {
    PINCache *cache = rootPath ? [[PINCache alloc] initWithName:name rootPath:rootPath] : [[PINCache alloc] initWithName:name];
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

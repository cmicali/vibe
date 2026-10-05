//
//  PINCache+VibeAudioCache.h
//  Vibe
//
//  The disk-cache policy shared by the two PINDiskCache-backed stores,
//  AudioTrackMetadataCache and AudioWaveformCache. One home stops the policies
//  drifting: both key off the same file identity, through NSURL+Hash, and their
//  entries should live and die on the same terms.
//

#import <Foundation/Foundation.h>
#import "PINCache.h"

NS_ASSUME_NONNULL_BEGIN

@interface PINCache (VibeAudioCache)

// A store with the shared byte and age limits applied, under rootPath, nil for
// the user's caches.
// TRAP: never PINCache's own objectForKey: or setObject:forKey:. Both enter
// memoryCache at cost 0, which a costLimit never evicts, and on macOS
// PINMemoryCache has no memory-pressure hook either, so every entry ever read
// would stay for the app's lifetime. The metadata store reads and writes
// diskCache alone; the waveform store gives memoryCache a costLimit and costs
// every entry it puts there.
+ (PINCache *)audioCacheWithName:(NSString *)name rootPath:(nullable NSString *)rootPath;

// Entry count and total bytes on disk. The enumeration blocks, so call it on
// the store's own serial queue; the completion is dispatched to the main thread.
- (void)audioDiskUsageWithCompletion:(void (^)(NSUInteger fileCount,
                                               unsigned long long totalBytes))completion;

@end

NS_ASSUME_NONNULL_END

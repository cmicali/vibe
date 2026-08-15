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

// A store with the shared byte and age limits applied. Both stores then read
// and write diskCache directly, because on macOS PINMemoryCache never evicts —
// costLimit needs per-entry costs, disk hits repopulate at cost 0, and its
// memory-pressure hooks are iOS-only — so it would pin every entry ever loaded
// for the app's lifetime.
+ (PINCache *)audioCacheWithName:(NSString *)name;

// Entry count and total bytes on disk. The enumeration blocks, so call it on
// the store's own serial queue; the completion is dispatched to the main thread.
- (void)audioDiskUsageWithCompletion:(void (^)(NSUInteger fileCount,
                                               unsigned long long totalBytes))completion;

@end

NS_ASSUME_NONNULL_END

//
//  VibePlayableItem.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// What the pieces that read a file take of an app's item: its file, its
// window, and the two keys it is matched by. The player, the metadata loader
// and the waveform cache keep the item they were given and hand that same
// object back, so two items for one file stay two items. Nothing about tags,
// tempo, key, names or art: those are the app's.
@protocol VibePlayableItem <NSObject>

// The file. Opens, claims and metadata are per file.
@property (copy, readonly) NSURL *url;

// The window, in CD frames (CueWindowMath.h): start inclusive, end exclusive,
// and an end of 0 runs to the file's end. 0 and 0 is the whole file. Fixed
// before the item crosses a thread.
@property (readonly) NSUInteger cueStart;
@property (readonly) NSUInteger cueEnd;

// Source identity: what sounds, the file's path plus its window. Shared work,
// the park and the successor match on it. Compared on per-tick paths, so it
// must be fixed and allocate nothing. An identity to compare, never a path to
// open.
- (NSString *)sourceKey;

// Version identity: the file's NSURL+Hash cacheKey, which persisted entries
// match on. nil when the file cannot be statted, and the caller then skips
// caching. An item may memoize it, stamped with NSURL.cacheKeyGeneration.
- (nullable NSString *)cacheKey;

// The window's length in seconds, as the player settled it. Written on the
// player queue at every settlement, promote and length settle.
- (void)setDuration:(NSTimeInterval)duration;

@end

// `key` with the window appended, so the windows of one file key apart: `key`
// itself for a whole file, and nil for nil. Persisted waveform entries are
// spelled with it, so the spelling never changes.
static inline NSString *_Nullable VibeKeyByAppendingCueWindow(NSString *_Nullable key, NSUInteger cueStart,
                                                              NSUInteger cueEnd) {
    return key && (cueStart > 0 || cueEnd > 0)
            ? [NSString stringWithFormat:@"%@#%lu-%lu", key, (unsigned long)cueStart, (unsigned long)cueEnd]
            : key;
}

// YES when `next` is the next window of `item`'s file, beginning where it
// ends: one recording, which continues without a gap whatever the crossfade.
static inline BOOL VibePlayableItemIsFollowedContiguouslyBy(id<VibePlayableItem> _Nullable item,
                                                            id<VibePlayableItem> _Nullable next) {
    return item && next && item.cueEnd > 0 && next.cueStart == item.cueEnd && [next.url isEqual:item.url];
}

NS_ASSUME_NONNULL_END

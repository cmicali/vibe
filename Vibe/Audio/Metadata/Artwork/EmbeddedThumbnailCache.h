//
//  EmbeddedThumbnailCache.h
//  Vibe
//
//  The decoded row thumbnails every AudioTrackArtwork shares.
//

#import <Foundation/Foundation.h>

#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface EmbeddedThumbnailKey : NSObject <NSCopying>
@end

// An explicit LRU: NSCache treats its limits as suggestions, and this bound
// must hold.
@interface EmbeddedThumbnailCache : NSObject
- (nullable VibeImage *)imageForKey:(EmbeddedThumbnailKey *)key;
- (void)setImage:(VibeImage *)image forKey:(EmbeddedThumbnailKey *)key;
- (void)removeImageForKey:(EmbeddedThumbnailKey *)key;
- (void)removeAllImages;
@property (nonatomic, readonly) NSUInteger count;
@end

// The bound: kEmbeddedThumbnailCacheCount, unless a test set the override.
NSUInteger VibeEmbeddedThumbnailCacheLimit(void);
// Test-only; 0 restores the production bound.
void VibeEmbeddedThumbnailCacheSetLimitOverride(NSUInteger limit);

// The one cache. iOS empties it on a memory warning.
EmbeddedThumbnailCache *VibeEmbeddedThumbnailCache(void);

NS_ASSUME_NONNULL_END

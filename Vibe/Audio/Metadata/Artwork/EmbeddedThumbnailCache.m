//
//  EmbeddedThumbnailCache.m
//  Vibe
//

#import "EmbeddedThumbnailCache.h"
#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

// A session's scrolled rows stay decoded (spec H): <=128px RGBA, ~64 KiB each,
// ~1 GiB only at 16k distinct rows. iOS flushes it on a memory warning rather
// than carrying a byte cap.
static const NSUInteger kEmbeddedThumbnailCacheCount = 16384;
static NSUInteger sLimitOverride = 0;
NSUInteger VibeEmbeddedThumbnailCacheLimit(void) {
    return sLimitOverride ?: kEmbeddedThumbnailCacheCount;
}
void VibeEmbeddedThumbnailCacheSetLimitOverride(NSUInteger limit) {
    sLimitOverride = limit;
}

@implementation EmbeddedThumbnailKey
- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}
@end

// TRAP: _images is the sole owner of every node; the links are unowned (strong
// ones would cycle along the chain). Safe only because every removal unlinks
// the node first, in the same critical section.
@interface EmbeddedThumbnailNode : NSObject
@property (nonatomic, strong) VibeImage *image;
@property (nonatomic, strong) EmbeddedThumbnailKey *key;
@property (nonatomic, unsafe_unretained, nullable) EmbeddedThumbnailNode *newer;
@property (nonatomic, unsafe_unretained, nullable) EmbeddedThumbnailNode *older;
@end

@implementation EmbeddedThumbnailNode
@end

// Lookup, recency updates and each eviction are O(1). Every row draw hits it.
@implementation EmbeddedThumbnailCache {
    NSMutableDictionary<EmbeddedThumbnailKey *, EmbeddedThumbnailNode *> *_images;
    __unsafe_unretained EmbeddedThumbnailNode *_mostRecent;
    __unsafe_unretained EmbeddedThumbnailNode *_leastRecent;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _images = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Recency list. All four run with the monitor held.

- (void)unlinkNode:(EmbeddedThumbnailNode *)node {
    if (node.newer) {
        node.newer.older = node.older;
    }
    else if (_mostRecent == node) {
        _mostRecent = node.older;
    }
    if (node.older) {
        node.older.newer = node.newer;
    }
    else if (_leastRecent == node) {
        _leastRecent = node.newer;
    }
    node.newer = nil;
    node.older = nil;
}

- (void)linkNodeAtHead:(EmbeddedThumbnailNode *)node {
    node.older = _mostRecent;
    node.newer = nil;
    _mostRecent.newer = node;
    _mostRecent = node;
    if (!_leastRecent) {
        _leastRecent = node;
    }
}

- (void)touchNode:(EmbeddedThumbnailNode *)node {
    if (_mostRecent == node) {
        return;
    }
    [self unlinkNode:node];
    [self linkNodeAtHead:node];
}

// Unlink before the removal that frees, so a caller may pass the unowned
// _leastRecent.
// TRAP: the strong local is load-bearing. Once the row is gone the dictionary
// and the node hold the key's only references (copyWithZone: returns self),
// so the removal would otherwise hash a key its own value had just freed.
- (void)evictNode:(EmbeddedThumbnailNode *)node {
    EmbeddedThumbnailKey *key = node.key;
    [self unlinkNode:node];
    [_images removeObjectForKey:key];
}

#pragma mark -

- (VibeImage *)imageForKey:(EmbeddedThumbnailKey *)key {
    @synchronized (self) {
        EmbeddedThumbnailNode *node = _images[key];
        if (!node) {
            return nil;
        }
        [self touchNode:node];
        return node.image;
    }
}

- (void)setImage:(VibeImage *)image forKey:(EmbeddedThumbnailKey *)key {
    @synchronized (self) {
        EmbeddedThumbnailNode *node = _images[key];
        if (node) {
            node.image = image;
            [self touchNode:node];
        }
        else {
            node = [[EmbeddedThumbnailNode alloc] init];
            node.image = image;
            node.key = key;
            _images[key] = node;
            [self linkNodeAtHead:node];
        }
        while (_images.count > VibeEmbeddedThumbnailCacheLimit() && _leastRecent) {
            [self evictNode:_leastRecent];
        }
    }
}

- (void)removeImageForKey:(EmbeddedThumbnailKey *)key {
    @synchronized (self) {
        EmbeddedThumbnailNode *node = _images[key];
        if (node) {
            [self evictNode:node];
        }
    }
}

- (void)removeAllImages {
    @synchronized (self) {
        // The unowned ends must not outlive the nodes.
        _mostRecent = nil;
        _leastRecent = nil;
        [_images removeAllObjects];
    }
}

- (NSUInteger)count {
    @synchronized (self) {
        return _images.count;
    }
}

@end

EmbeddedThumbnailCache *VibeEmbeddedThumbnailCache(void) {
    static EmbeddedThumbnailCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[EmbeddedThumbnailCache alloc] init];
#if !TARGET_OS_OSX
        // No pressure eviction of its own; visible rows re-request.
        [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification *note) {
            (void)note;
            [cache removeAllImages];
        }];
#endif
    });
    return cache;
}

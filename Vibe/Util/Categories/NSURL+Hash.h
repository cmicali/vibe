//
//  NSURL+Hash.h
//  Vibe
//

#import <Foundation/Foundation.h>

@interface NSData (Hash)

// Lowercase hex SHA-1: the one spelling cacheKey and AppTheme's image names
// share.
- (nonnull NSString *)sha1Hex;

@end

@interface NSURL (Hash)

// "<size>-<mtime_us>-<sha1(path)>" of the symlink-resolved path, from one stat
// and no content read. Changes with size, mtime or resolved path. A rewrite
// that preserves size and mtime keeps the key. nil when the stat fails;
// callers must then skip caching.
- (nullable NSString *)cacheKey;

// What a memoized cacheKey is stamped with. A memo stamped below the current
// generation is stale, so its next read stats the file again. Any thread.
@property (class, readonly) uint64_t cacheKeyGeneration;

// A file was replaced under its URL by another version: a download that
// installed something other than its placeholder's size and mtime. Every
// memoized cacheKey goes stale. Any thread.
+ (void)invalidateMemoizedCacheKeys;

// A "which track is this" key (the widget's): hex SHA-1 of the comparable path
// (VibeComparablePath), relative to the app's home for a file inside it. From
// the spelling alone, so it never stats. Survives a rewrite. nil for a URL
// with no path.
//
// TRAP: the data container moves (every simulator install, possibly an iOS
// update), so a key over the absolute path would disagree with every consumer
// that captured it before the move. Hence home-relative.
- (nullable NSString *)pathKey;

@end

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

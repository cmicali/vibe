//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSURL (Hash)

// Cheap identity key for caching: "<size>-<mtime_us>-<sha1(path)>", computed
// from the symlink-resolved path so links key off their target's identity.
// Reads file attributes only (no file body), so it's microseconds vs. tens of
// milliseconds for a content hash. Cache misses on rewrite (mtime changes)
// and rename/move (path hash changes). nil when the file can't be statted —
// no stable identity to cache under; callers must skip caching on nil.
- (nullable NSString *)cacheKey;

@end

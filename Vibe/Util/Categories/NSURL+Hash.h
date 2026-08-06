//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSURL (Hash)

// A cheap identity key for caching: "<size>-<mtime_us>-<sha1(path)>", computed
// from the symlink-resolved path, so that a link keys off its target's
// identity. It reads file attributes only, never the file body, so it takes
// microseconds against the tens of milliseconds a content hash would cost. It
// misses on a rewrite, where the mtime changes, and on a rename or move, where
// the path hash changes. It is nil when the file cannot be statted, since
// there is then no stable identity to cache under, and callers must skip
// caching on nil.
- (nullable NSString *)cacheKey;

@end

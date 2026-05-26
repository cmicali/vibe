//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSURL (Hash)

//- (NSString *)md5HashOfFile;
- (NSString *)sha1HashOfFile;
- (NSString *)sha512HashOfFile;

// Cheap identity key for caching: "<size>-<mtime_us>-<sha1(path)>". Reads
// file attributes only (no file body), so it's microseconds vs. tens of
// milliseconds for a content hash. Cache misses on rewrite (mtime changes)
// and rename/move (path hash changes).
- (NSString *)cacheKey;

@end

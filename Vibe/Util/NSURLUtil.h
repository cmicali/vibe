//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface NSURLUtil : NSObject

// Playable file extensions (lowercase, no dot).
+ (NSSet<NSString *> *)supportedExtensions;

// YES for a cloud placeholder whose data is not local — iCloud, Dropbox, any
// File Provider. APFS marks these SF_DATALESS, and reading one blocks until
// the provider materializes it. stat() itself never triggers the download, so
// this check is always fast. It returns NO when the stat fails, since unknown
// is not the same as dataless.
+ (BOOL)isDatalessFile:(NSURL *)url;

+ (NSArray<NSURL *> *)expandDirectory:(NSURL *)dir;

+ (NSArray<NSURL *> *)expandAndFilterList:(NSArray<NSURL *> *)list;

+ (void)expandAndFilterList:(NSArray<NSURL *> *)list completion:(void (^)(NSArray<NSURL *> *))completion;

+ (NSArray<NSURL *> *)expandFileList:(NSArray<NSURL *> *)list;
@end

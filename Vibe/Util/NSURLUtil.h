//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface NSURLUtil : NSObject

// YES for a cloud placeholder whose data is not local — iCloud, Dropbox, any
// File Provider. APFS marks these SF_DATALESS, and reading one blocks until
// the provider materializes it. stat() itself never triggers the download, so
// this check is always fast. It returns NO when the stat fails, since unknown
// is not the same as dataless.
+ (BOOL)isDatalessFile:(NSURL *)url;

// Expands folders and top-level playlist files (the files a .cue/.m3u/.m3u8
// lists, in list order, raising a folder-access grant when the sandbox
// requires one), and filters to playable extensions. Expansions run on a
// four-wide queue, so one dead folder cannot block an unrelated later open and
// a burst of them cannot spawn a thread each; callers coordinate overlapping
// result order (OpenRequestCoordinator). folderCount is how many of the
// top-level URLs resolved as directories, counted here because the check stats
// the file system and so belongs on the expansion queue, not the main-thread
// caller. Completion runs on main.
+ (void)expandAndFilterList:(NSArray<NSURL *> *)list
                 completion:(void (^)(NSArray<NSURL *> *files, NSUInteger folderCount))completion;
@end

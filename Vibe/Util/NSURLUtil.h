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

// Expands folders, filters to playable extensions, and preserves submission
// order: expansion runs on a serial queue, so overlapping drops complete in
// the order they were submitted and a slow folder walk cannot finish after a
// later drop's and replace the newer playlist. folderCount is how many of the
// top-level URLs resolved as directories, counted here because the check stats
// the file system and so belongs on the expansion queue, not the main-thread
// caller. Completion runs on main.
+ (void)expandAndFilterList:(NSArray<NSURL *> *)list
                 completion:(void (^)(NSArray<NSURL *> *files, NSUInteger folderCount))completion;
@end

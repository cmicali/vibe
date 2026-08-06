//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSURLUtil.h"

#include <sys/stat.h>


@implementation NSURLUtil

+ (BOOL)isDatalessFile:(NSURL *)url {
    struct stat st;
    if (stat(url.fileSystemRepresentation, &st) != 0) {
        return NO;
    }
    return (st.st_flags & SF_DATALESS) != 0;
}

// A static set, consulted once per file in a folder drop.
+ (NSSet<NSString*>*) supportedExtensions {
    static NSSet<NSString*> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithObjects:@"mp2", @"mp3", @"aac", @"aif", @"aiff", @"wav", @"flac", @"m4a", @"mp4", nil];
    });
    return extensions;
}

+ (NSArray<NSURL*>*) expandDirectory:(NSURL*)dir {

    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] init];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // Skip hidden files. On exFAT, SMB and USB volumes macOS writes
    // AppleDouble sidecars such as "._Song.mp3", whose extension passes the
    // filetype filter but which hold resource-fork metadata rather than audio;
    // each one showed up as a duplicate, unplayable playlist row. Skipping
    // package descendants keeps the walk out of app and bundle internals.
    NSDirectoryEnumerator *enumerator = [fileManager
            enumeratorAtURL:dir
 includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                    options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
               errorHandler:^(NSURL *url, NSError *error) {
                   // Skip the unreadable entry or subtree, but keep
                   // enumerating the rest of the drop.
                   LogWarn(@"Error enumerating %@: %@", url, error);
                   return YES;
               }];
    for (NSURL *url in enumerator) {
        NSError *error = nil;
        NSNumber *isDirectory = nil;
        if ([url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&error]) {
            if (![isDirectory boolValue]) {
                [results addObject:url];
            }
        }
        else {
            // Log it and treat it as a file, the same fallback expandFileList:
            // uses, so that it still reaches the extension filter rather than
            // vanishing.
            LogWarn(@"Could not read directory flag for %@: %@", url, error);
            [results addObject:url];
        }
    }

    // The enumerator returns APFS hash order, which is effectively random, so
    // sort by full path with Finder's comparator, which is numeric and groups
    // subfolders. An explicit multi-file drop keeps its pasteboard order; see
    // expandFileList:.
    [results sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.path localizedStandardCompare:b.path];
    }];

    return results;
}

// Serial, so that overlapping drops complete in submission order. Expanded
// concurrently, a slow folder walk could finish after a later single file's and
// replace the newer playlist mid-listen.
+ (dispatch_queue_t)expansionQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.vibe.urlexpansion",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    });
    return queue;
}

+ (void) expandAndFilterList:(NSArray<NSURL*>*)list completion:(void (^)(NSArray<NSURL*>*))completion {
    dispatch_async([self expansionQueue], ^{
        NSArray<NSURL*> *results = [self expandAndFilterList:list];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(results);
        });
    });
}

+ (NSArray<NSURL*>*) expandAndFilterList:(NSArray<NSURL*>*)list {
    list = [NSURLUtil expandFileList:list];
    NSSet<NSString*> *supported = [NSURLUtil supportedExtensions];
    list = [list filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary* bindings) {
        return [supported containsObject:[url.pathExtension lowercaseString]];
    }]];
    return list;
}

+ (NSArray<NSURL*>*) expandFileList:(NSArray<NSURL*>*)list {
    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] initWithCapacity:list.count];
    for (NSURL *url in list) {
        // Ask the filesystem rather than the URL. hasDirectoryPath inspects
        // only the trailing slash, so a directory URL built without
        // isDirectory:YES — from an argv path or some pasteboards — would be
        // treated as a file and then silently dropped by the extension filter.
        NSNumber *isDirectory = nil;
        BOOL isDir = [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL]
                ? isDirectory.boolValue
                : url.hasDirectoryPath; // resource read failed; fall back to the slash
        if (isDir) {
            [results addObjectsFromArray:[self expandDirectory:url]];
        }
        else {
            [results addObject:url];
        }
    }
    return results;
}

@end

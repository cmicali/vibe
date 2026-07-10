//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSURLUtil.h"


@implementation NSURLUtil

+ (NSArray<NSURL*>*) expandDirectory:(NSURL*)dir {

    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] init];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // Skip hidden files: on exFAT/SMB/USB volumes macOS writes AppleDouble
    // sidecars ("._Song.mp3") whose extension passes the filetype filter but
    // which hold resource-fork metadata, not audio — each one showed up as a
    // duplicate, unplayable playlist row. Skipping package descendants keeps
    // the walk out of app/bundle internals.
    NSDirectoryEnumerator *enumerator = [fileManager
            enumeratorAtURL:dir
 includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                    options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
               errorHandler:^(NSURL *url, NSError *error) {
                   // Handle the error.
                   // Return YES if the enumeration should continue after the error.
                   return YES;
               }];
    for (NSURL *url in enumerator) {
        NSError *error;
        NSNumber *isDirectory = nil;
        if ([url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&error]) {
            if (![isDirectory boolValue]) {
                [results addObject:url];
            }
        }
    }

    return results;
}

// Serial so overlapping drops complete in submission order. On the old
// concurrent queue a slow folder expansion could finish after a later single
// file's and replace the newer playlist mid-listen.
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
    list = [list filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary* bindings) {
        return [VIBE_SUPPORTED_FILETYPES containsObject:[url.pathExtension lowercaseString]];
    }]];
    return list;
}

+ (NSArray<NSURL*>*) expandFileList:(NSArray<NSURL*>*)list {
    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] initWithCapacity:list.count];
    for (NSURL *url in list) {
        if (url.hasDirectoryPath) {
            [results addObjectsFromArray:[self expandDirectory:url]];
        }
        else {
            [results addObject:url];
        }
    }
    return results;
}

@end

//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSURLUtil.h"


@implementation NSURLUtil

+ (NSArray<NSURL*>*) expandDirectory:(NSURL*)dir {

    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] init];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSDirectoryEnumerator *enumerator = [fileManager
            enumeratorAtURL:dir
 includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                    options:0
               errorHandler:^(NSURL *url, NSError *error) {
                   // Handle the error.
                   // Return YES if the enumeration should continue after the error.
                   return YES;
               }];
    for (NSURL *url in enumerator) {
        NSError *error;
        NSNumber *isDirectory = nil;
        if ([url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&error]) {
            if ([isDirectory boolValue]) {
                [results addObjectsFromArray:[self expandDirectory:url]];
            }
            else {
                [results addObject:url];
            }
        }
    }

    return results;
}

+ (NSArray<NSURL*>*) expandAndFilterList:(NSArray<NSURL*>*)list {
    list = [NSURLUtil expandFileList:list];
    list = [list filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary* bindings) {
        return [ALLOWED_FILETYPES containsObject:[url.pathExtension lowercaseString]];
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

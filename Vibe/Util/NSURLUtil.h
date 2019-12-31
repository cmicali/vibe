//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface NSURLUtil : NSObject

+ (NSArray<NSURL *> *)expandDirectory:(NSURL *)dir;

+ (NSArray<NSURL *> *)expandAndFilterList:(NSArray<NSURL *> *)list;

+ (NSArray<NSURL *> *)expandFileList:(NSArray<NSURL *> *)list;
@end

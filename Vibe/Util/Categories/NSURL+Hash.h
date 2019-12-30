//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSURL (Hash)

- (NSString *)md5HashOfFile;
- (NSString *)sha1HashOfFile;
- (NSString *)sha512HashOfFile;

@end

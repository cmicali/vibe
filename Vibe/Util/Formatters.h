//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

// MAIN THREAD ONLY: NSDateComponentsFormatter (unlike NSDateFormatter) has no
// documented thread-safety guarantee.
@interface Formatters : NSObject

+ (Formatters *)sharedInstance;

- (NSString *)durationStringFromTimeInterval:(NSTimeInterval)duration;

@end

//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface Formatters : NSObject

+ (Formatters *)sharedInstance;

- (NSDateComponentsFormatter *)timeFormatter;

- (NSString *)durationStringFromTimeInterval:(NSTimeInterval)duration;

@end

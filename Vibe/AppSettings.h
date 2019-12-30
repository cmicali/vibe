//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface AppSettings : NSObject

+ (AppSettings*)sharedInstance;

- (NSInteger)audioPlayerCurrentDevice;
- (void)setAudioPlayerCurrentDevice:(NSInteger)deviceIndex;

@end

//
// Created by Christopher Micali on 12/28/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@class AudioPlayer;

@interface OutputDevicesMenuController : NSObject <NSMenuDelegate,
                                             NSMenuItemValidation>

@property (weak) AudioPlayer *audioPlayer;

@end

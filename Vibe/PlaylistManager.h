//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import "AudioTrack.h"
#import "BASSAudioPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlaylistManager : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property NSUInteger currentIndex;

@property (weak) BASSAudioPlayer *audioPlayer;

- (id)initWithAudioPlayer:(BASSAudioPlayer *)player;

- (void)reset:(NSArray<NSURL *> *)urls;
- (AudioTrack *)currentTrack;

@end

NS_ASSUME_NONNULL_END
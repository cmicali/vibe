//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import "AudioTrack.h"
#import "AudioPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlaylistManager : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property NSUInteger currentIndex;

@property (weak) AudioPlayer *audioPlayer;
@property (weak) NSTableView *tableView;

- (id)initWithAudioPlayer:(AudioPlayer *)player;

- (void)reset:(NSArray<NSURL *> *)urls;

- (void)play;

- (BOOL)next;

- (AudioTrack *)currentTrack;

- (NSUInteger)count;

- (NSInteger)getIndexForTrack:(AudioTrack *)track;
@end

NS_ASSUME_NONNULL_END

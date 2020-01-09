//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import "AudioTrack.h"
#import "AudioPlayer.h"

@class AudioTrackMetadataCache;

NS_ASSUME_NONNULL_BEGIN

@interface PlaylistManager : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property NSUInteger currentIndex;

@property (weak) AudioTrackMetadataCache *metadataCache;
@property (weak) AudioPlayer *audioPlayer;

- (NSArray<AudioTrack *> *)playlist;

- (id)initWithAudioPlayer:(AudioPlayer *)player metadataCache:(AudioTrackMetadataCache *)metadataCache tableView:(NSTableView *)view;

- (void)play;
- (void)play:(NSArray<NSURL *> *)urls;
- (BOOL)next;

- (AudioTrack * _Nullable)currentTrack;
- (NSUInteger)count;

- (NSInteger)getIndexForTrack:(AudioTrack *)track;

- (void)reloadCurrentTrack;
- (void)reloadTrackAtIndex:(NSUInteger)index;
- (void)reloadTrack:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END

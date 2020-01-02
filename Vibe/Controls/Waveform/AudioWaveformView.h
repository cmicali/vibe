//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>

#include "AudioWaveformCache.h"

NS_ASSUME_NONNULL_BEGIN

@protocol AudioWaveformViewDelegate;
@class AudioTrack;

@interface AudioWaveformView : NSView

@property (nullable, weak) id <AudioWaveformViewDelegate> delegate;

@property CGFloat progress;

- (void)loadWaveformForTrack:(AudioTrack *)track;

@end

@protocol AudioWaveformViewDelegate <NSObject>
@optional

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage;

@end

NS_ASSUME_NONNULL_END

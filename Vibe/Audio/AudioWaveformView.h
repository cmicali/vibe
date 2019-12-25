//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>

@protocol AudioWaveformViewDelegate;
@class AudioWaveform;

@interface AudioWaveformView : NSView

@property (nullable, weak) id <AudioWaveformViewDelegate> delegate;

@property CGFloat progress;

- (void)setWaveform:(AudioWaveform *)waveform;

@end

@protocol AudioWaveformViewDelegate <NSObject>
@optional

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage;

@end
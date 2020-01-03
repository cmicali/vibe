//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>
#import "AudioWaveform.h"

@class AudioWaveform;

NS_ASSUME_NONNULL_BEGIN

@interface AudioWaveformRenderer : NSObject

@property (assign) CGFloat topY;
@property (assign) CGFloat bottomY;

- (NSString *)displayName;

- (void)updateWaveformBounds:(CGFloat)top bottom:(CGFloat)bottom;

- (void)willDrawRect:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform;
- (void)drawRect:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform;
- (void)didDrawRect:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform;

@end

NS_ASSUME_NONNULL_END

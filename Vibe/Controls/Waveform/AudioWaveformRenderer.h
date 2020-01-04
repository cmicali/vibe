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

- (instancetype)initWithLayer:(CALayer*)layer bounds:(CGRect)bounds;

+ (NSString *)displayName;

- (void)updateWaveformBounds:(CGFloat)top bottom:(CGFloat)bottom;

- (void)willUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform * __nullable)waveform;
- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;
- (void)didUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform * __nullable)waveform;
- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;

@end

NS_ASSUME_NONNULL_END

//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>
#import "AudioWaveform.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioWaveformRenderer : NSObject

@property (assign) CGFloat topY;
@property (assign) CGFloat bottomY;
@property (assign) CGFloat progress;
@property (assign) BOOL isDark;

// Last "played" bar index that updateProgress: painted. Layer-array renderers
// (only SonicCirrusWaveformRenderer nowadays — the bar-layer machinery itself
// lives there) use this to repaint just the bars between the old and new
// progress boundary instead of every bar. Set to -1 to force a full repaint
// (e.g. after the played/unplayed colors change in updateColors:).
@property (assign) NSInteger lastProgressBoundary;

@property (strong) CALayer* parentLayer;

+ (NSString *)displayName;

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark;

- (void)updateColors:(BOOL)isDark;

- (void) setGradientLayerColors:(CAGradientLayer*)layer colors:(NSArray<NSColor*>*)colors;

- (void)willUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform * __nullable)waveform;
- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;
- (void)didUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform * __nullable)waveform;
- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;

@end

NS_ASSUME_NONNULL_END

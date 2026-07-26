//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>
#import "AudioWaveform.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioWaveformRenderer : NSObject

@property (assign) BOOL isDark;

// Last "played" bar index that updateProgress: painted. Layer-array renderers
// (SonicCirrusWaveformRenderer, which owns the bar-layer machinery) use this
// to repaint just the bars between the old and new progress boundary instead
// of every bar. Set to -1 to force a full repaint (e.g. after the
// played/unplayed colors change in updateColors:).
@property (assign) NSInteger lastProgressBoundary;

@property (strong) CALayer* parentLayer;

// Stable, never-localized key for this renderer: the NSUserDefaults value, the
// AudioWaveformView registry key, and the stem of the menu item's identifier.
// displayName is the localized name and must never be used as a key.
+ (NSString *)styleIdentifier;

// Localized, user-visible name. Display only.
+ (NSString *)displayName;

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark;

- (void)updateColors:(BOOL)isDark;

// Vertical band (view coords) a click must land in to count as a seek.
// Queried by AudioWaveformView on mouseDown and computed from the given
// bounds alone — a pure function, not per-draw mutable state, so each
// renderer has exactly one band definition. Base: the middle 50% of the
// height; renderers with a known drawn extent override.
- (NSRect)seekHitBandForBounds:(NSRect)bounds;

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;
- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;

@end

NS_ASSUME_NONNULL_END

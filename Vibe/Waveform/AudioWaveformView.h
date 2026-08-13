//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioWaveformViewDelegate;
@class CodableAudioWaveform;

// A pure rendering surface: it draws whatever waveform it is handed and
// reports seek clicks. Loading and caching live in AudioWaveformCache, which
// MainPlayerController owns. The controller asks the cache to load and routes
// the deliveries through TrackDisplayController's pass-throughs, which reset
// this view with prepareForWaveformLoad and hand results to showWaveform:.
@interface AudioWaveformView : NSView

@property (nullable, weak) id <AudioWaveformViewDelegate> delegate;

@property CGFloat progress;

// Styles are identified by the renderer's stable styleIdentifier, never its
// localized display name; displayNameForStyle: turns one into UI text.
- (NSString *)currentWaveformStyle;
- (void)setWaveformStyle:(NSString *)identifier;
- (NSArray<NSString *> *)availableWaveformStyles;
- (NSString *)displayNameForStyle:(NSString *)identifier;

// Clears the previous track's waveform ahead of a new load, and installs the
// persisted renderer style on first use.
- (void)prepareForWaveformLoad;

// Renders a waveform snapshot: a progressive one mid-load, or the final or
// cache-hit waveform. It retains the snapshot, because the wrapper owns the
// C++ chunk buffer the renderers read.
- (void)showWaveform:(CodableAudioWaveform *)waveform;

// Convert to FLAC progress: the bars between the previous fraction and this
// one collapse to the midline and ease back — a brush moving through the
// waveform. A smaller value just moves the front back; prepareForWaveformLoad
// and the empty and loading states reset it.
@property (nonatomic) double convertSweepFraction;

// An indeterminate shimmer across the waveform area while a slow file open is
// pending, as when a cloud placeholder is downloading.
- (void)showLoadingIndicator;
- (void)hideLoadingIndicator;
// Determinate download progress while the loading indicator shows: the
// midline fills to fraction beneath the shimmer. Negative reverts to
// indeterminate. No-op unless the loading indicator is up.
- (void)setLoadingProgress:(float)fraction;

// The no-track empty state: a static full-width line on the waveform midline.
// prepareForWaveformLoad and showLoadingIndicator clear it when a track
// arrives.
- (void)showEmptyPlaceholder;

- (void)updateAppearance;
@end

@protocol AudioWaveformViewDelegate <NSObject>

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage;

@end

NS_ASSUME_NONNULL_END

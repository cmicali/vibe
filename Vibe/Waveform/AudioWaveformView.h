//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioWaveformViewDelegate;
@class CodableAudioWaveform;

// Pure rendering surface: draws whatever waveform it is handed and reports
// seek clicks. Loading and caching live in AudioWaveformCache, owned by
// MainPlayerController — the controller resets this view (prepareForWaveformLoad),
// asks the cache to load, and forwards the cache's deliveries to showWaveform:.
@interface AudioWaveformView : NSView

@property (nullable, weak) id <AudioWaveformViewDelegate> delegate;

@property CGFloat progress;

- (NSString *)currentWaveformStyle;
- (void)setWaveformStyle:(NSString*)name;
- (NSArray<NSString *> *)availableWaveformStyles;

// Clears the previous track's waveform ahead of a new load (and installs the
// persisted renderer style on first use).
- (void)prepareForWaveformLoad;

// Renders a waveform snapshot — a progressive one mid-load, or the final /
// cache-hit waveform. Retains it: the wrapper owns the C++ chunk buffer the
// renderers read.
- (void)showWaveform:(CodableAudioWaveform *)waveform;

// Indeterminate shimmer across the waveform area while a slow file open
// (e.g. a cloud placeholder downloading) is pending.
- (void)showLoadingIndicator;
- (void)hideLoadingIndicator;

- (void)updateAppearance;
@end

@protocol AudioWaveformViewDelegate <NSObject>
@optional

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage;

@end

NS_ASSUME_NONNULL_END

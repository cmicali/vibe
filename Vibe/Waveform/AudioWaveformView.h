//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioWaveformViewDelegate;
@class AudioTrack;

@interface AudioWaveformView : NSView

@property (nullable, weak) id <AudioWaveformViewDelegate> delegate;

@property CGFloat progress;

- (NSString *)currentWaveformStyle;
- (void)setWaveformStyle:(NSString*)name;
- (NSArray<NSString *> *)availableWaveformStyles;

- (void)loadWaveformForTrack:(AudioTrack *)track;

// Empties the waveform disk cache (the view owns the cache). Completion fires
// on the cache's queue once the entries are gone.
- (void)invalidateCacheWithCompletion:(nullable dispatch_block_t)completion;

// Indeterminate shimmer across the waveform area while a slow file open
// (e.g. a cloud placeholder downloading) is pending.
- (void)showLoadingIndicator;
- (void)hideLoadingIndicator;

- (void)updateAppearance;
@end

@protocol AudioWaveformViewDelegate <NSObject>
@optional

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage;

// Fired once per completed waveform load (fresh analysis or cache hit) when
// the decode pass detected a tempo. Never fired with 0.
- (void)audioWaveformView:(AudioWaveformView *)waveformView didDetectBPM:(float)bpm;

@end

NS_ASSUME_NONNULL_END

//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioWaveform.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Waveform Cache

@class AudioTrack;
@protocol AudioWaveformCacheDelegate;

@interface AudioWaveformCache : NSObject

@property (nullable, weak) id <AudioWaveformCacheDelegate> delegate;

- (void)invalidate;
- (void)loadWaveformForTrack:(AudioTrack *)track;

@end

@protocol AudioWaveformCacheDelegate <NSObject>
@optional

// Passes the ARC-managed wrapper so receivers can retain it — the raw
// AudioWaveform* is owned by (and dies with) the wrapper.
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded;

@end

NS_ASSUME_NONNULL_END

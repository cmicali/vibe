//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Waveform Cache

// Kept a forward declaration (its header defines C++ classes): importing
// AudioWaveform.h here would force every transitive importer — most of the
// UI layer — to compile as ObjC++.
@class CodableAudioWaveform;
@class AudioTrack;
@protocol AudioWaveformCacheDelegate;

@interface AudioWaveformCache : NSObject

@property (nullable, weak) id <AudioWaveformCacheDelegate> delegate;

- (void)invalidate;
// Completion fires on the cache's serial loader queue once the disk cache is
// actually empty — behind any in-flight waveform load on that queue.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;
- (void)loadWaveformForTrack:(AudioTrack *)track;

@end

@protocol AudioWaveformCacheDelegate <NSObject>
@optional

// Passes the ARC-managed wrapper so receivers can retain it — the raw
// AudioWaveform* is owned by (and dies with) the wrapper.
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded;

@end

NS_ASSUME_NONNULL_END

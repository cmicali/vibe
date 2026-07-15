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
// Completion fires on the cache's serial loader queue once the disk cache has
// been emptied. Decodes already in flight (they run on a global queue, not
// the loader queue) can't repopulate it: their disk writes are dropped by a
// cache-generation check, though their UI delivery still happens.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;
- (void)loadWaveformForTrack:(AudioTrack *)track;

@end

@protocol AudioWaveformCacheDelegate <NSObject>
@optional

// Passes the ARC-managed wrapper so receivers can retain it — the raw
// AudioWaveform* is owned by (and dies with) the wrapper.
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded;

// Fired once per completed waveform load (fresh analysis or cache hit) when
// the decode pass detected a tempo — never with 0. Follows the final
// didLoadData: delivery, on the main thread. url is the file the waveform was
// loaded for: a final delivery can race a track change (land after next: but
// before the cancel is observed), so receivers must match it against their
// current track rather than assume it.
- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END

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

#if DEBUG
// Debug / pre-warm: decode and persist the waveform (and its detected BPM) for
// a file WITHOUT cancelling or delivering to the current load — the running UI
// is left untouched. Runs the same lookup-or-decode path as a normal load, but
// a fresh decode's completion waits for the disk write, so once it fires the
// entry is durably cached. completion fires on the main thread: ok is NO on
// decode failure; wasCached is YES when the entry already existed (no decode
// ran); bpm is 0 when none was detected.
- (void)cacheWaveformForURL:(NSURL *)url
                 completion:(void (^)(BOOL ok, BOOL wasCached, float bpm))completion;

// Debug: remove a single file's waveform cache entry. The cache key is derived
// from the file's current size + mtime, so the file must still exist unchanged
// to resolve the same entry. completion fires on the main thread with whether
// an entry was present.
- (void)clearCachedWaveformForURL:(NSURL *)url
                       completion:(void (^)(BOOL wasPresent))completion;
#endif

@end

@protocol AudioWaveformCacheDelegate <NSObject>

// Passes the ARC-managed wrapper so receivers can retain it — the raw
// AudioWaveform* is owned by (and dies with) the wrapper.
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded;

@optional

// Fired once per completed waveform load (fresh analysis or cache hit) when
// the decode pass detected a tempo — never with 0. Follows the final
// didLoadData: delivery, on the main thread. url is the file the waveform was
// loaded for: a final delivery can race a track change (land after next: but
// before the cancel is observed), so receivers must match it against their
// current track rather than assume it.
- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END

//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Waveform Cache

// Kept as a forward declaration, because its header defines C++ classes.
// Importing AudioWaveform.h here would force every transitive importer, which
// means most of the UI layer, to compile as ObjC++.
@class CodableAudioWaveform;
@class AudioTrack;
@protocol AudioWaveformCacheDelegate;

@interface AudioWaveformCache : NSObject

@property (nullable, weak) id <AudioWaveformCacheDelegate> delegate;

// The PINCache store name, derived from the entry format version; see the
// implementation. It is the single source for init and for anything that
// reports the name, such as the debug clear_caches reply.
+ (NSString *)cacheName;

// The completion fires on the cache's serial loader queue once the disk cache
// has been emptied. Decodes already in flight run on a global queue rather
// than the loader queue, and they cannot repopulate it: a cache-generation
// check drops their disk writes, though their UI delivery still happens.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;

// The backing store's entry count and total bytes on disk, enumerated off the
// calling thread; the completion runs on the main thread.
- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion;

- (void)loadWaveformForTrack:(AudioTrack *)track;
// Cancels the in-flight load, if there is one, so there are no further
// waveform deliveries until the next loadWaveformForTrack:. A decode that has
// already completed may still persist to disk, and its BPM is still delivered,
// tagged with its URL for the receiver to match against its playlist. Only the
// waveform UI delivery is dropped.
- (void)cancelLoad;

#if DEBUG
// Debug and pre-warm: decodes and persists a file's waveform, and its detected
// BPM and key, without cancelling or delivering to the current load, so the
// running UI is untouched. It runs the same lookup-or-decode path as a normal
// load, but a fresh decode's completion waits for the disk write, so the entry
// is durably cached once it fires. The completion fires on the main thread: ok
// is NO on a decode failure, wasCached is YES when the entry already existed
// and no decode ran, bpm is 0 and key is -1 when none was detected.
- (void)cacheWaveformForURL:(NSURL *)url
                 completion:(void (^)(BOOL ok, BOOL wasCached, float bpm, NSInteger key))completion;

// Debug: removes a single file's waveform cache entry. The cache key derives
// from the file's current size and mtime, so the file must still exist
// unchanged to resolve the same entry. The completion fires on the main thread
// with whether an entry was present.
- (void)clearCachedWaveformForURL:(NSURL *)url
                       completion:(void (^)(BOOL wasPresent))completion;
#endif

@end

@protocol AudioWaveformCacheDelegate <NSObject>

// Passes the ARC-managed wrapper so that receivers can retain it. The wrapper
// owns the raw AudioWaveform*, which dies with it.
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded;

@optional

// Fires once per completed waveform load, whether a fresh analysis or a cache
// hit, when the decode pass detected a tempo. It never fires with 0. It
// follows the final didLoadData: delivery, on the main thread. url is the file
// the waveform was loaded for: a final delivery can race a track change,
// landing after next: but before the cancel is observed, so receivers must
// match it against their current track rather than assume it.
- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forURL:(NSURL *)url;

// The key detection twin of didDetectBPM:, with the same timing, threading
// and URL-matching contract. key is a valid VibeMusicalKey — it never fires
// with VibeMusicalKeyNone.
- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectKey:(NSInteger)key forURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END

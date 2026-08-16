//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
// VibeWaveformAnalysisProvider, stamped onto every loader this cache creates.
#import "AudioWaveformLoader.h"

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

// Whether a decode should also run the tempo and key analyzers. Stamped onto
// every loader this cache creates, and asked once per load, so a settings
// change lands on the next decode. The owner installs it: macOS reads the two
// analysis settings, iOS installs nothing because it never analyzes.
@property (nullable, copy) VibeWaveformAnalysisProvider analysisProvider;

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

// Both main thread only, like the delegate deliveries they gate.
- (void)loadWaveformForTrack:(AudioTrack *)track;
// Supersedes the in-flight load, if there is one, so there are no further
// waveform deliveries until the next loadWaveformForTrack:. The decode is NOT
// aborted: it detaches, runs to completion in the background, and persists,
// so the next request for that file is a disk hit — a skip-ahead or a pager
// peek no longer throws the decode away. Up to two detached decodes run at
// once; beyond that the oldest is genuinely cancelled. A request for a file
// whose detached decode is still running reattaches it instead of starting a
// second one. BPM and key from a detached decode are still delivered, tagged
// with their URL for the receiver to match against its playlist.
- (void)cancelLoad;

@end

@protocol AudioWaveformCacheDelegate <NSObject>

// Passes the ARC-managed wrapper so that receivers can retain it. The wrapper
// owns the raw AudioWaveform*, which dies with it. url is the file it was
// loaded for: a load is cancelled when the *next* one starts, so a track
// change that pauses on a slow open leaves the outgoing decode streaming
// snapshots meanwhile, and the receiver matches rather than assumes, like
// every other delivery here.
- (void)audioWaveform:(CodableAudioWaveform *)waveform
          didLoadData:(float)percentLoaded
               forURL:(NSURL *)url;

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

//
//  AudioWaveformCache.h
//  Vibe
//

#import <Foundation/Foundation.h>
// VibeWaveformAnalysis, stamped onto every loader this cache creates.
#import "AudioWaveformLoader.h"
#import "VibePlayableItem.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Waveform Cache

// Kept as a forward declaration, because its header defines C++ classes.
// Importing AudioWaveform.h here would force every transitive importer, which
// means most of the UI layer, to compile as ObjC++.
@class CodableAudioWaveform;
@class AudioWorkToken;
@protocol AudioWaveformCacheDelegate;

typedef VibeWaveformAnalysis (^VibeWaveformAnalysisProvider)(void);

@interface AudioWaveformCache : NSObject

@property (nullable, weak) id <AudioWaveformCacheDelegate> delegate;

// What a decode should compute beyond the waveform: the bands and the
// observers. A provider rather than a value because it is asked once per
// request, on the main thread, so a settings change lands on the next request
// with nobody republishing it; and that answer is the request's loader's, so
// the lookup and the decode agree. Unset is none of it. A cached entry
// without the bands or an observer's result misses for a request asking for
// it, so an owner that comes to want more asks for its track again
// (AGENTS.md).
@property (nullable, copy) VibeWaveformAnalysisProvider analysisProvider;

// The PINCache store name, derived from the entry format version; see the
// implementation. It is the single source for init and for anything that
// reports the name, such as the debug clear_caches reply.
+ (NSString *)cacheName;

// The store under rootPath rather than the user's caches: the tests' own.
- (instancetype)initWithRootPath:(nullable NSString *)rootPath NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

// The completion fires on the cache's serial loader queue once the disk cache
// has been emptied. Decodes already in flight run through the cache's
// fixed-slot utility scheduler rather than the loader queue, and they cannot
// repopulate it: a cache-generation check drops their disk writes, though
// their UI delivery still happens.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;

// The backing store's entry count and total bytes on disk, enumerated off the
// calling thread; the completion runs on the main thread.
- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion;

// Both main thread only, like the delegate deliveries they gate.
- (void)loadWaveformForTrack:(id<VibePlayableItem>)track;

// Main-thread request and completion. Reads only the disk cache, without
// opening audio or retargeting the active load. A miss answers nil; cancelling
// pending work drops its completion. Preview stats cannot occupy active slots.
- (AudioWorkToken *)cachedWaveformForTrack:(id<VibePlayableItem>)track
                   completion:(void (^)(CodableAudioWaveform * _Nullable waveform))completion;
// Main-thread request and completion. Reads blocks of a complete waveform's
// window at full resolution into its detail, for deep zoom, on a lane of its
// own: one read running and one waiting. A file not on disk is skipped, since
// a zoom must never start a download. The completion runs once the blocks
// are in or could not be read. Cancelling pending work drops it.
- (AudioWorkToken *)loadDetailBlocks:(NSIndexSet *)blocks
                            forTrack:(id<VibePlayableItem>)track
                            waveform:(CodableAudioWaveform *)waveform
                          completion:(dispatch_block_t)completion;

// Supersedes the in-flight load: no further waveform deliveries until the
// next loadWaveformForTrack:. The decode is NOT aborted: it detaches, runs to
// completion and persists, so the next request for that file is a disk hit;
// a file still streaming decodes only while the play's stream lasts, and
// ends unpersisted when the play lets it go.
// Up to two detached decodes run at once; beyond that the oldest is
// cancelled, and its uncancellable stat/open worker keeps the path's claim
// until it returns, so a same-file request waits and restarts once rather
// than adding a stranded worker. A live detached decode is reattached in
// place. A detached decode's results are still delivered, with the track they
// were loaded for. The receiver matches it against its playlist.
- (void)cancelLoad;

@end

@protocol AudioWaveformCacheDelegate <NSObject>

// Passes the ARC-managed wrapper so that receivers can retain it. The wrapper
// owns the raw AudioWaveform*, which dies with it. track is the one it was
// loaded for — the latest request's, when a same-window request reattached
// the decode: a load is cancelled when the *next* one starts, so a track
// change that pauses on a slow open leaves the outgoing decode streaming
// snapshots meanwhile, and the receiver matches rather than assumes, like
// every other delivery here. Match by sourceKey: a cue row's data is its
// window's, never its file's.
- (void)audioWaveform:(CodableAudioWaveform *)waveform
          didLoadData:(float)percentLoaded
             forTrack:(id<VibePlayableItem>)track;

@optional

// A load that cannot produce a complete waveform has ended. It fires on the
// main thread only while that load is still current; track lets a receiver
// drop a failure that raced a track change just like a data delivery. A later
// loadWaveformForTrack: starts a fresh attempt for the same window.
- (void)audioWaveformCache:(AudioWaveformCache *)cache didFailToLoadForTrack:(id<VibePlayableItem>)track;

// Delivers an entry's results, by observer identifier, on main after a
// completed load or cache hit, whenever it holds any. They may include
// observers this request did not list. Active loads deliver them after final
// didLoadData:. Detached loads and cache previews can deliver them without a
// waveform callback. Match the track's sourceKey against each playlist row
// before installing a result.
- (void)audioWaveformCache:(AudioWaveformCache *)cache
            didLoadResults:(NSDictionary<NSString *, NSNumber *> *)results
                  forTrack:(id<VibePlayableItem>)track;

@end

NS_ASSUME_NONNULL_END

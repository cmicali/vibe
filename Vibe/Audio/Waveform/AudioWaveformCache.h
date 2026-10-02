//
//  AudioWaveformCache.h
//  Vibe
//

#import <Foundation/Foundation.h>
// VibeWaveformAnalysis, stamped onto every loader this cache creates.
#import "AudioWaveformLoader.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Waveform Cache

// Kept as a forward declaration, because its header defines C++ classes.
// Importing AudioWaveform.h here would force every transitive importer, which
// means most of the UI layer, to compile as ObjC++.
@class CodableAudioWaveform;
@class AudioTrack;
@protocol AudioWaveformCacheDelegate;

typedef VibeWaveformAnalysis (^VibeWaveformAnalysisProvider)(void);

@interface AudioWaveformCache : NSObject

@property (nullable, weak) id <AudioWaveformCacheDelegate> delegate;

// What a decode should compute beyond the waveform. A provider rather than a
// value because it is asked once per request, on the main thread, so a
// settings change lands on the next request with nobody republishing it; and
// that answer is the request's loader's, so the lookup and the decode agree on
// the bands. Unset is none of it. A cached entry without the bands misses for
// a request asking for them, so an owner that comes to want them asks for its
// track again (AGENTS.md).
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
- (void)loadWaveformForTrack:(AudioTrack *)track;
// Supersedes the in-flight load: no further waveform deliveries until the
// next loadWaveformForTrack:. The decode is NOT aborted: it detaches, runs to
// completion and persists, so the next request for that file is a disk hit;
// a file still streaming decodes only while the play's stream lasts, and
// ends unpersisted when the play lets it go.
// Up to two detached decodes run at once; beyond that the oldest is
// cancelled, and its uncancellable stat/open worker keeps the path's claim
// until it returns, so a same-file request waits and restarts once rather
// than adding a stranded worker. A live detached decode is reattached in
// place. BPM and key from a detached decode are still delivered, tagged with
// their URL for the receiver to match against its playlist.
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
             forTrack:(AudioTrack *)track;

@optional

// A load that cannot produce a complete waveform has ended. It fires on the
// main thread only while that load is still current; track lets a receiver
// drop a failure that raced a track change just like a data delivery. A later
// loadWaveformForTrack: starts a fresh attempt for the same window.
- (void)audioWaveformCache:(AudioWaveformCache *)cache didFailToLoadForTrack:(AudioTrack *)track;

// Fires once per completed waveform load, whether a fresh analysis or a cache
// hit, when the decode pass detected a tempo. It never fires with 0. It
// follows the final didLoadData: delivery, on the main thread. track is the
// one the waveform was loaded for: a final delivery can race a track change,
// landing after next: but before the cancel is observed, so receivers must
// match it against their current track rather than assume it.
- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forTrack:(AudioTrack *)track;

// The key detection twin of didDetectBPM:, with the same timing, threading
// and matching contract. key is a valid VibeMusicalKey — it never fires with
// VibeMusicalKeyNone.
- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectKey:(NSInteger)key forTrack:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END

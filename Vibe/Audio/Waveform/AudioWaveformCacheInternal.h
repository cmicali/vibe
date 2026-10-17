//
//  AudioWaveformCacheInternal.h
//  Vibe
//
//  The state and the lookup-or-decode path the debug seam's per-file cache
//  control shares with the delegate path (AudioWaveformCache+Debug.mm).
//

#import "AudioWaveformCache.h"

@class AudioWorkScheduler;
@class AudioWaveformLoader;
@class CodableAudioWaveform;
@class PINCache;
@class VibeWaveformLoadClaim;

NS_ASSUME_NONNULL_BEGIN

@interface AudioWaveformCache () {
    dispatch_queue_t                _loaderQueue;
    // Stat and open cannot be interrupted; fixed slots bound blocked workers.
    AudioWorkScheduler              *_lookupScheduler;
    AudioWorkScheduler              *_previewScheduler;
    // Deep zoom's reads, apart from the decodes, so a stuck one holds no
    // decode slot.
    AudioWorkScheduler              *_detailScheduler;
    AudioWorkScheduler              *_decodeScheduler;
    PINCache*                       _waveformCache;
}

// The lookup-or-decode path every load takes. AudioWaveformCache.mm states
// its contract.
- (void)load:(AudioTrack *)track
    cacheKey:(NSString *)cacheKey
  withLoader:(AudioWaveformLoader *)loader
       claim:(nullable VibeWaveformLoadClaim *)claim
awaitPersist:(BOOL)awaitPersist
  completion:(void (^)(CodableAudioWaveform *_Nullable waveform, BOOL wasCached))completion
     settled:(nullable dispatch_block_t)settled;

@end

NS_ASSUME_NONNULL_END

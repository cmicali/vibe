//
//  AudioWaveformCache+Debug.mm
//  Vibe
//

#import "AudioWaveformCache+Debug.h"

#if DEBUG

#import "AudioWaveformCacheInternal.h"
#import "AudioWaveform.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AudioWaveformLoader.h"
#import "AudioWorkScheduler.h"

#include <atomic>

@implementation AudioWaveformCache (Debug)

#pragma mark - Debug: decode pace

static std::atomic<double> sDebugDecodeSeconds{0};

+ (NSTimeInterval)debugDecodeSeconds {
    return sDebugDecodeSeconds;
}

+ (void)setDebugDecodeSeconds:(NSTimeInterval)seconds {
    sDebugDecodeSeconds = MAX(0.0, seconds);
}

#pragma mark - Debug: per-file cache control

// The lookup-or-decode path for one file, apart from the UI's load. The
// completion runs on main with nil on failure.
- (void)waveformForURL:(NSURL *)url completion:(void (^)(CodableAudioWaveform *, BOOL wasCached))completion {
    AudioTrack *track = [AudioTrack withURL:url];
    // A private loader, never assigned to _currentLoader. The UI's in-flight
    // load is not cancelled, and no delegate progress or delivery fires; this
    // path reports through the completion instead. The typed nil delegate
    // local dodges -Wnonnull.
    id<AudioWaveformLoaderDelegate> noDelegate = nil;
    AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] initWithDelegate:noDelegate];
    loader.analysis = self.analysisProvider ? self.analysisProvider() : (VibeWaveformAnalysis){};
    // The key is computed off the loader queue; see loadWaveformForTrack:.
    [_lookupScheduler submitWork:^{
        NSString *cacheKey = track.cacheKey;
        if (!cacheKey) {
            LogWarn(@"No cache key for %@ — cannot cache waveform", url.path);
            run_on_main_thread({ completion(nil, NO); });
            return;
        }
        dispatch_sync(self->_loaderQueue, ^{
            [self load:track cacheKey:cacheKey withLoader:loader claim:nil
                    awaitPersist:YES completion:^(CodableAudioWaveform *waveform, BOOL wasCached) {
                run_on_main_thread({ completion(waveform, wasCached); });
            } settled:nil];
        });
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        LogWarn(@"Waveform cache admission exhausted for %@ (%ld)",
                url.path, (long)failure);
        completion(nil, NO);
    }];
}

- (void)cacheWaveformForURL:(NSURL *)url completion:(void (^)(BOOL, BOOL, float, NSInteger))completion {
    [self waveformForURL:url completion:^(CodableAudioWaveform *waveform, BOOL wasCached) {
        float bpm = waveform.bpm; // nil → 0
        // Explicitly -1 for nil: messaging nil returns 0, which as a
        // key would read as C major.
        NSInteger key = waveform ? waveform.key : -1;
        if (completion) completion(waveform != nil, wasCached, bpm, key);
    }];
}

- (void)dumpWaveformForURL:(NSURL *)url columns:(NSUInteger)columns
                completion:(void (^)(NSDictionary *))completion {
    [self waveformForURL:url completion:^(CodableAudioWaveform *codable, BOOL wasCached) {
        AudioWaveform *waveform = codable.waveform;
        if (!waveform) {
            completion(nil);
            return;
        }
        NSUInteger chunks = waveform->getNumChunks();
        NSUInteger count = columns ? MIN(columns, chunks) : chunks;
        NSMutableArray *mins = [NSMutableArray arrayWithCapacity:count];
        NSMutableArray *maxes = [NSMutableArray arrayWithCapacity:count];
        NSMutableArray *meanSquares = [NSMutableArray arrayWithCapacity:count];
        NSMutableArray *frames = [NSMutableArray arrayWithCapacity:count];
        NSMutableArray *bands[kAudioWaveformBandCount];
        for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
            bands[b] = [NSMutableArray arrayWithCapacity:count];
        }
        std::vector<float> bandMeanSquares(count * kAudioWaveformBandCount);
        waveform->getBarMeanSquares(count, 0, nullptr, bandMeanSquares.data());
        for (NSUInteger i = 0; i < count; i++) {
            AudioWaveformCacheChunk chunk = waveform->getChunkAtIndex(i, count);
            [mins addObject:@(chunk.getMin())];
            [maxes addObject:@(chunk.getMax())];
            [meanSquares addObject:@(chunk.getMeanSquare())];
            [frames addObject:@(chunk.getFrameCount())];
            for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
                [bands[b] addObject:@(bandMeanSquares[i * kAudioWaveformBandCount + b])];
            }
        }
        completion(@{
            @"path": url.path, @"wasCached": @(wasCached), @"complete": @(waveform->isComplete()),
            @"chunks": @(chunks), @"columns": @(count), @"hasBands": @(waveform->hasBands()),
            @"bpm": @(codable.bpm), @"key": @(codable.key),
            @"min": mins, @"max": maxes, @"meanSquare": meanSquares, @"frames": frames,
            @"bands": @{@"low": bands[0], @"mid": bands[1], @"high": bands[2]},
        });
    }];
}

- (void)clearCachedWaveformForURL:(NSURL *)url completion:(void (^)(BOOL))completion {
    AudioTrack *track = [AudioTrack withURL:url];
    // The key is computed off the loader queue; see loadWaveformForTrack:.
    [_lookupScheduler submitWork:^{
        NSString *cacheKey = track.cacheKey;
        if (!cacheKey) {
            // The file cannot be statted, so its entry cannot be resolved
            // anyway: the key derives from the current size and mtime.
            LogWarn(@"No cache key for %@ — cannot clear waveform entry", url.path);
            run_on_main_thread({ if (completion) completion(NO); });
            return;
        }
        dispatch_sync(self->_loaderQueue, ^{
            BOOL present = [self->_waveformCache.diskCache containsObjectForKey:cacheKey];
            [self->_waveformCache.diskCache removeObjectForKey:cacheKey];
            run_on_main_thread({ if (completion) completion(present); });
        });
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        LogWarn(@"Waveform clear admission exhausted for %@ (%ld)",
                url.path, (long)failure);
        if (completion) completion(NO);
    }];
}

@end

#endif

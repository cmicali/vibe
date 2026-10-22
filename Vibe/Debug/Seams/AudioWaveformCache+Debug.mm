//
//  AudioWaveformCache+Debug.mm
//  Vibe
//

#import "AudioWaveformCache+Debug.h"

#if DEBUG

#import "AudioWaveformCacheInternal.h"
#import "AudioWaveform.h"
#import "PINCache.h"
#import "AudioWaveformLoader.h"
#import "AudioWorkScheduler.h"
#import "HelperMacros.h"
#import "VibeMacros.h"

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

// The lookup-or-decode path for one track, apart from the UI's load. The
// completion runs on main with nil on failure.
- (void)waveformForTrack:(id<VibePlayableItem>)track completion:(void (^)(CodableAudioWaveform *, BOOL wasCached))completion {
    NSURL *url = track.url;
    // A private loader, never assigned to _currentLoader. The UI's in-flight
    // load is not cancelled, and no delegate progress or delivery fires; this
    // path reports through the completion instead, so it has no delegate.
    AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] init];
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

- (void)cacheWaveformForTrack:(id<VibePlayableItem>)track
                   completion:(void (^)(BOOL, BOOL, NSDictionary<NSString *, id> *))completion {
    [self waveformForTrack:track completion:^(CodableAudioWaveform *waveform, BOOL wasCached) {
        if (completion) completion(waveform != nil, wasCached, waveform.results ?: @{});
    }];
}

- (void)dumpWaveformForTrack:(id<VibePlayableItem>)track columns:(NSUInteger)columns
                  completion:(void (^)(NSDictionary *))completion {
    NSURL *url = track.url;
    [self waveformForTrack:track completion:^(CodableAudioWaveform *codable, BOOL wasCached) {
        AudioWaveform *waveform = codable.waveform;
        if (!waveform) {
            completion(nil);
            return;
        }
        // Omitted, 8,192 columns across the whole window.
        NSUInteger count = columns ? columns : 8192;
        double framesPerColumn = (double)waveform->totalFrames() / (double)count;
        NSMutableArray *mins = [NSMutableArray arrayWithCapacity:count];
        NSMutableArray *maxes = [NSMutableArray arrayWithCapacity:count];
        NSMutableArray *loudest = [NSMutableArray arrayWithCapacity:count];
        NSMutableArray *bandLoudest[wavecore::kBandCount];
        for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
            bandLoudest[b] = [NSMutableArray arrayWithCapacity:count];
        }
        std::vector<wavecore::Column> grid(count);
        waveform->columns(framesPerColumn, 0, count, grid.data());
        for (const wavecore::Column &column : grid) {
            [mins addObject:@(column.lo)];
            [maxes addObject:@(column.hi)];
            [loudest addObject:@(column.loudest)];
            for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
                [bandLoudest[b] addObject:@(column.bandLoudest[b])];
            }
        }
        completion(@{
            @"path": url.path, @"wasCached": @(wasCached), @"complete": @(waveform->isComplete()),
            @"bins": @(waveform->binCount()), @"binFrames": @(waveform->binFrames()),
            @"frames": @(waveform->totalFrames()), @"sampleRate": @(waveform->sampleRate()),
            @"columns": @(count), @"hasBands": @(waveform->hasBands()),
            @"results": codable.results,
            @"min": mins, @"max": maxes, @"loudest": loudest,
            @"bandLoudest": @{@"low": bandLoudest[0], @"mid": bandLoudest[1], @"high": bandLoudest[2]},
        });
    }];
}

- (void)clearCachedWaveformForTrack:(id<VibePlayableItem>)track completion:(void (^)(BOOL))completion {
    NSURL *url = track.url;
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

//
//  AudioPlayer+Debug.m
//  Vibe
//

#import "AudioPlayer+Debug.h"

#if DEBUG

#import "AudioPlayerInternal.h"
#import "AudioMasterBusInternal.h"
#import "AudioFX+Pipeline.h"
#import "AudioLevelPublisher+Debug.h"
#import "VibeManualRenderPump.h"
#include <stdatomic.h>
#include <unistd.h>

@implementation AudioPlayer (Debug)

#pragma mark - Manual rendering and introspection

- (instancetype)initForManualRendering:(AVAudioFormat *)format enableFX:(BOOL)enableFX automatic:(BOOL)automatic delegate:(id<AudioPlayerDelegate>)delegate {
    NSParameterAssert(format.commonFormat == AVAudioPCMFormatFloat32 && !format.interleaved);
    return [self initWithDeviceUID:@"" modelUID:@"" name:@"" enableFX:enableFX delegate:delegate
                        manualPump:[[VibeManualRenderPump alloc] initWithFormat:format automatic:automatic]];
}

- (AVAudioPCMBuffer *)debugRenderFrames:(AVAudioFrameCount)frames error:(NSError **)error {
    __block AVAudioPCMBuffer *buffer;
    __block NSError *failure;
    [self runSyncOnQueue:^{ buffer = [(VibeManualRenderPump *)self->_manualPump renderFrames:frames error:&failure]; }];
    if (error) *error = failure;
    return buffer;
}

- (void)debugSetCapture:(void (^)(AVAudioPCMBuffer *))capture {
    [self runSyncOnQueue:^{ [(VibeManualRenderPump *)self->_manualPump setCapture:capture]; }];
}

- (void)debugBlockQueueForSeconds:(NSTimeInterval)seconds {
    dispatch_async(_queue, ^{ usleep((useconds_t)(MIN(10, MAX(0, seconds)) * 1e6)); });
}

- (void)debugStarveDecoder:(BOOL)starve {
    [self runSyncOnQueue:^{ [(VibeManualRenderPump *)self->_manualPump setStarveDecoder:starve]; }];
}

- (void)debugShutdown {
    self.delegate = nil;
    [self runSyncOnQueue:^{
        self->_terminating = YES;
        [self stopOnQueue];
        [(VibeManualRenderPump *)self->_manualPump cancel];
        [self stopOutputOnQueue];
    }];
}

// dump_audio_loading compares the three consumers' snapshots — the
// materialization coordinator's, the metadata cache's and this one.
- (AudioLoadingConfiguration *)loadingConfiguration {
    __block AudioLoadingConfiguration *configuration;
    [self runSyncOnQueue:^{ configuration = self->_loadingConfiguration; }];
    return configuration;
}

- (NSDictionary<NSString *, NSNumber *> *)debugBufferingRecord {
    os_unfair_lock_lock(&_stateLock);
    NSDictionary *record = @{
        @"holds": @(_debugBufferingHolds),
        @"releases": @(_debugBufferingReleases),
        @"stalls": @(_debugBufferingStalls),
        @"heldSeconds": @(_buffering ? NSProcessInfo.processInfo.systemUptime - _debugBufferingSinceUptime
                                     : _debugBufferingLastHeldSeconds),
    };
    os_unfair_lock_unlock(&_stateLock);
    return record;
}

- (BOOL)manualRenderingActive {
    return _manualPump != nil;
}

- (AudioLevelMeter *)debugLevelMeter {
    __block AudioLevelMeter *meter;
    [self runSyncOnQueue:^{ meter = self->_levelMeter; }];
    return meter;
}

- (void)debugClearRenderCounters {
    [self runSyncOnQueue:^{
        [self->_outputUnit clearCounters];
        [self clearRenderRefusalsOnQueue];
    }];
}

- (NSDictionary<NSString *, NSNumber *> *)debugRenderCounts {
    __block NSDictionary *counts = nil;
    [self runSyncOnQueue:^{
        VibeVoiceSnapshot snapshot = [self->_voiceBus snapshotOfVoice:self->_voice];
        NSDictionary *unit = [self outputUnitCountersOnQueue];
        NSDictionary *varispeed = [self pipelineRenderSnapshotOnQueue][@"varispeed"];
        counts = @{@"hostedUnits": @(self.fx.hostedUnitCount),
                   @"unitRenders": @(self.fx.unitRenders),
                   @"outputDropouts": unit[@"dropouts"],
                   @"renderCycles": unit[@"renderCycles"],
                   @"renderMeanMicros": unit[@"renderMeanMicros"],
                   @"renderMaxMicros": unit[@"renderMaxMicros"],
                   @"retiredFades": @(self->_retiringVoices.count),
                   @"prefetched": @(self->_prefetchedFile != nil),
                   @"renderLeaveWork": @(self->_renderLeaveWork.count),
                   @"renderRefusals": @([self renderRefusalsOnQueue]),
                   @"rendersHeld": @([self debugRendersHeld]),
                   @"liveVoices": @(self->_voiceBus.liveVoiceCount),
                   @"decodeTurns": @(self->_voiceBus.decodeTurns),
                   @"pollActive": @(self->_drainTimer != nil),
                   @"running": @([self renderingOnQueue]),
                   @"frames": @([(VibeManualRenderPump *)self->_manualPump renderedFrames]),
                   @"varispeed": @([self varispeedPresentOnQueue]),
                   @"fxConnected": @(self.fx.connected),
                   @"gain": @(snapshot.gain),
                   @"underrunFrames": @(snapshot.underrunFrames),
                   @"varispeedLatency": @([self varispeedLatencyOnQueue]),
                   @"varispeedEngaged": varispeed[@"engaged"],
                   @"varispeedRenders": varispeed[@"renders"],
                   @"varispeedHistoryWrites": varispeed[@"historyWrites"],
                   @"outputRate": @([self masterBusFormatOnQueue].sampleRate)};
    }];
    return counts;
}

- (BOOL)debugSetOutputRate:(double)rate {
    __block BOOL followed = NO;
    [self runSyncOnQueue:^{
        AVAudioFormat *current = [self masterBusFormatOnQueue];
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate
                                                                             channels:current ? current.channelCount : 2];
        followed = [self followOutputFormatOnQueue:format];
    }];
    return followed;
}

- (NSDictionary<NSString *, id> *)debugCurrentConversion {
    __block NSDictionary *conversion;
    [self runSyncOnQueue:^{ conversion = [self->_voiceBus conversionOfVoice:self->_voice]; }];
    return conversion;
}

- (NSDictionary<NSString *, id> *)debugResamplerCostsResetting:(BOOL)reset {
    __block NSDictionary *costs;
    [self runSyncOnQueue:^{ costs = [self->_voiceBus debugResamplerCostsResetting:reset]; }];
    return costs;
}

static NSString *VibeAudioLevelNormalizationModeName(VibeAudioLevelNormalizationMode normalizationMode) {
    switch (normalizationMode) {
        case VibeAudioLevelNormalizationModeBalancedSpectrum:
            return @"balanced";
        case VibeAudioLevelNormalizationModeSharedSpectrum:
            return @"spectrum";
        case VibeAudioLevelNormalizationModeRelativeActivity:
        default:
            return @"activity";
    }
}

- (void)debugSetEqualizerNormalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode {
    if (normalizationMode != VibeAudioLevelNormalizationModeRelativeActivity
            && normalizationMode != VibeAudioLevelNormalizationModeSharedSpectrum
            && normalizationMode != VibeAudioLevelNormalizationModeBalancedSpectrum) {
        return;
    }
    [self runSyncOnQueue:^{
        if (self->_levelNormalizationMode == normalizationMode) {
            return;
        }
        [self dropLevelMeterOnQueue];
        self->_levelNormalizationMode = normalizationMode;
        [self applyLevelMeterOnQueue];
    }];
}

- (NSDictionary<NSString *, id> *)debugEqualizerState {
    __block NSDictionary *state = nil;
    [self runSyncOnQueue:^{
        NSMutableDictionary<NSString *, id> *snapshot = [[self->_levelPublisher debugState] mutableCopy];
        snapshot[@"requested"] = @(self->_levelsWanted);
        snapshot[@"signalProbe"] = @(self.signalProbeWanted); // beta builds' hold for a start's capture
        snapshot[@"meterObject"] = @(self->_levelMeter != nil);
        snapshot[@"retiredOutputCount"] = @(self->_retiringVoices.count);
        snapshot[@"outputAudioActive"] = @(self.outputAudioActive);
        snapshot[@"normalizationMode"] = VibeAudioLevelNormalizationModeName(self->_levelNormalizationMode);
        state = snapshot;
    }];
    return state;
}

#pragma mark - The pipeline

- (void)attachPumpOnQueue:(VibeManualRenderPump *)pump render:(VibeManualRenderBlock)render running:(BOOL (^)(void))running {
    // The pump stands in for the IO thread: the frame-driven mode decodes
    // inline before each slice, and both modes drain after it.
    __weak AudioPlayer *weakSelf = self;
    pump.beforeRender = pump.automatic ? nil : ^{
        AudioPlayer *strongSelf = weakSelf;
        [strongSelf->_voiceBus fillInline];
    };
    pump.afterRender = ^{ [weakSelf drainVoiceBusOnQueue]; };
    [pump attachRender:render running:running queue:_queue];
}

- (void)debugHoldDecoder:(BOOL)hold {
    [self runSyncOnQueue:^{ [self->_voiceBus debugHoldDecoder:hold]; }];
}

- (void)debugHoldRenderInside:(BOOL)hold {
    atomic_store_explicit(&_masterBus->holdRenderInside, hold ? 1 : 0, memory_order_seq_cst);
}

- (NSUInteger)debugRendersHeld {
    return (NSUInteger)atomic_load_explicit(&_masterBus->rendersHeld, memory_order_seq_cst);
}

// An output unit's callback on the caller's thread: buffers of its own, the
// pipeline's channels, nothing of the player's queue-owned state read.
- (void)debugRenderOnCallerThread:(NSUInteger)frames {
    VibeMasterBus *master = _masterBus;
    UInt32 count = (UInt32)MIN(frames, (NSUInteger)kVibeMasterBusMaxFrames);
    uint32_t channels = VibeMasterBusChannels(master);
    float *storage = calloc((size_t)count * 2 + 1, sizeof(float));
    UInt32 bytes = count * (UInt32)sizeof(float);
    VibeStereoBufferList list = { channels, {{ 1, bytes, storage }, { 1, bytes, storage + count }} };
    VibeMasterBusRender(master, NULL, count, (AudioBufferList *)&list);
    free(storage);
}

#pragma mark - The published state

- (NSUInteger)numChannels {
    os_unfair_lock_lock(&_stateLock);
    AudioFileHandle *file = _file;
    os_unfair_lock_unlock(&_stateLock);
    return file.processingFormat.channelCount;
}

@end

#endif

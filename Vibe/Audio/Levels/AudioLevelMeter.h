//
//  AudioLevelMeter.h
//  Vibe
//
//  Demand-driven FFT analysis for the five-bar equalizer, fed the render's
//  final samples. The meter lives from the first demand, replaced only when
//  the output's rate or the normalization mode changes.
//

#import <AVFAudio/AVFAudio.h>

#import "AudioLevelMath.h"
#import "AudioLevelPublisher.h"

NS_ASSUME_NONNULL_BEGIN

// The render's plain state, owned by the meter for its life; the master bus
// withdraws its pointer before the meter is freed.
typedef struct VibeLevelMeter VibeLevelMeter;

@interface AudioLevelMeter : NSObject

// The rate and the normalization mode are fixed for the meter's life. Nothing
// is published until install. nil for an unusable format or a failed
// allocation.
- (nullable instancetype)initWithFormat:(AVAudioFormat *)format
                               publisher:(AudioLevelPublisher *)publisher
                       normalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode
        NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// What the render feeds; valid for the meter's life.
- (VibeLevelMeter *)meter;
@property (nonatomic, readonly) double sampleRate;

// Begins a publisher session; the render restarts the analysis on seeing it,
// so no earlier audio is published. Idempotent. Player queue.
- (void)install;
// Ends the publisher session, so its snapshot is unavailable at once, and
// completes a pending signal capture. Idempotent. Player queue.
- (void)remove;
@property (nonatomic, readonly) BOOL installed;

// The beta signal probe, bounded to first signal or three seconds. Player
// queue. Poll returns YES while pending; removal completes a partial capture.
// The last snapshot survives removal.
- (uint64_t)beginSignalDiagnosticsAtTime:(AudioTimeStamp)startTime
                waitingForRetiredAudio:(BOOL)waiting
                            completion:(void (^)(NSDictionary<NSString *, id> *snapshot))completion;
// The last outgoing fade has settled. The clock is the timestamp's sample
// time, in the pipeline's frames; without one the capture's clock is unset.
- (void)endSignalOverlapAtTime:(AudioTimeStamp)time;
- (BOOL)pollSignalDiagnostics:(uint64_t)request;
- (NSDictionary<NSString *, id> *)signalDiagnosticSnapshot;

@end

// Non-interleaved float32 at the meter's rate. Publishes every
// VibeLevelPublicationFrameCount frames. Audio thread.
void VibeLevelMeterRender(VibeLevelMeter *meter, float * _Nonnull const * _Nonnull channels, UInt32 channelCount, UInt32 frames,
                          const AudioTimeStamp *timestamp) CA_REALTIME_API;

NS_ASSUME_NONNULL_END

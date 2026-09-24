//
//  AudioLevelTap.h
//  Vibe
//
//  Demand-driven FFT analysis for the shared five-bar equalizer indicator,
//  fed the final output samples by the render. AudioPlayer owns one publisher
//  for its lifetime, and one tap — the meter — from the first demand on,
//  replaced only when the output's rate or the normalization mode changes.
//

#import <AVFoundation/AVFoundation.h>

#import "AudioLevelMath.h"
#import "AudioLevelPublisher.h"

NS_ASSUME_NONNULL_BEGIN

// The render's plain state: the analyzer, the publisher's session and the
// accumulator the render fills. The tap owns it for its life; the master bus
// points the render at it while the meter is installed and withdraws the
// pointer before the tap is freed (AudioPlayer+Graph.h), so the render never
// reads memory the tap has freed.
typedef struct VibeLevelMeter VibeLevelMeter;

@interface AudioLevelTap : NSObject

// Allocates the analyzer and the accumulator for `format`'s rate, which is
// fixed for the tap's life: replace the tap at another rate. Nothing is
// published until install. Returns nil for an unusable format or a failed
// allocation. The normalization mode is fixed for the tap's lifetime too;
// replace the tap to switch modes and reset its analysis history.
- (nullable instancetype)initWithFormat:(AVAudioFormat *)format
                               publisher:(AudioLevelPublisher *)publisher
                       normalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode
        NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// What the render feeds; valid for the tap's life.
- (VibeLevelMeter *)meter;
@property (nonatomic, readonly) double sampleRate;

// Begins a publisher session and restarts the accumulator, so the first
// publication after an install carries no earlier audio; the render meters
// once the master bus points at the meter. Idempotent. Player queue.
- (void)install;
// Ends the publisher session, so its snapshot is unavailable at once, and
// completes a pending signal capture. Idempotent. Player queue.
- (void)remove;
@property (nonatomic, readonly) BOOL installed;

// Beta probe of the installed meter, bounded to first signal or three
// seconds. All calls and completion belong to the player queue. Poll returns
// YES while pending; removal and replacement also complete partial captures.
// No call creates demand or opens a file. The last snapshot survives removal.
- (uint64_t)beginSignalDiagnosticsAtTime:(nullable AVAudioTime *)startTime
                waitingForRetiredAudio:(BOOL)waiting
                            completion:(void (^)(NSDictionary<NSString *, id> *snapshot))completion;
// Called when the last outgoing fade has actually settled, including smoothing.
- (void)endSignalOverlapAtTime:(nullable AVAudioTime *)time;
- (BOOL)pollSignalDiagnostics:(uint64_t)request;
- (NSDictionary<NSString *, id> *)signalDiagnosticSnapshot;

@end

// The render's entry: `frames` of `channelCount` non-interleaved float32
// channels of the final output at the tap's rate, the block stamped
// `timestamp`. The meter accumulates a tap buffer's worth (about 100 ms, what
// the engine's tap delivered) and analyzes and publishes once it holds it,
// so the cadence and the averaging are the engine tap's. Audio thread: no
// allocation, lock, logging or Objective-C send.
void VibeLevelMeterRender(VibeLevelMeter *meter, float * _Nonnull const * _Nonnull channels, UInt32 channelCount, UInt32 frames,
                          const AudioTimeStamp *timestamp) CA_REALTIME_API;

NS_ASSUME_NONNULL_END

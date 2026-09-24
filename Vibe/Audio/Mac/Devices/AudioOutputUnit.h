//
//  AudioOutputUnit.h
//  Vibe
//
//  The output device, hosted by Vibe: one HALOutput audio unit bound to one
//  device, whose render callback pulls the engine's realtime manual-rendering
//  block into the device's buffers. AVAudioEngine's own output node is a
//  default output unit that follows the system default wherever it moves;
//  this one moves only when the player rebinds it (hogfollow.swift's `hal`
//  measurement, docs/future/bit-perfect-output.md).
//
//  The callback is a C function under the same realtime discipline as the
//  voice bus's render: plain memory and atomics, no lock, allocation,
//  Objective-C or dispatch call. It decides nothing. A gate the queue opens in
//  start and closes in stop says whether the engine's block is called at all;
//  closed, the callback writes silence, so a render that lands during a
//  rebuild or before the engine started is silence, never a block or a call
//  into a stopped engine. Every method here is player-queue confined except
//  the two clock reads.
//

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioOutputUnit : NSObject

// A HALOutput instance with output enabled, input disabled and the callback
// installed. nil when the component cannot be instantiated.
- (nullable instancetype)init;

// The bound device: a field, never a HAL read; kAudioObjectUnknown before the
// first bind.
@property (nonatomic, readonly) AudioDeviceID deviceID;
// What the unit pulls at: the engine's manual rendering format. nil until configured.
@property (nonatomic, readonly, nullable) AVAudioFormat *format;
// Between start and stop.
@property (nonatomic, readonly) BOOL running;
// Device plus stream latency and the safety offset, read at bind, in seconds.
@property (nonatomic, readonly) NSTimeInterval presentationLatency;
// For the report's channel-map read only.
@property (nonatomic, readonly) AudioUnit audioUnit;
// IO cycles the engine could not render, so silence was written. Cumulative.
@property (nonatomic, readonly) uint64_t dropouts;

// Stopped only. Sets kAudioOutputUnitProperty_CurrentDevice.
- (OSStatus)bindToDevice:(AudioDeviceID)deviceID;

// Stopped only: uninitialize, set the input stream format, remember the block
// and the largest pull it accepts, initialize. The frame counter restarts at 0.
- (BOOL)configureFormat:(AVAudioFormat *)format
      maximumFrameCount:(AVAudioFrameCount)maximumFrameCount
            renderBlock:(AVAudioEngineManualRenderingBlock)renderBlock
                  error:(NSError * _Nullable * _Nullable)error;

// Opens the gate, then starts the unit; a refused start closes it again.
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
// Closes the gate, stops the unit, and returns with no render inside the callback.
- (void)stop;

// Any thread. The engine-timeline frame the next render begins at, plus the
// block in flight: the same one-block exclusion the engine's output node gave.
- (AVAudioTime *)renderTime;
// Any thread. The device's timestamp of the last IO cycle; zero flags before the first.
- (AudioTimeStamp)lastIOTimeStamp;

@end

NS_ASSUME_NONNULL_END

//
//  AudioOutputUnit.h
//  Vibe
//
//  The output device, hosted by Vibe: one HALOutput audio unit bound to one
//  device, whose render callback pulls the player's render proc into the
//  device's buffers. AVAudioEngine's own output node is a default output unit
//  that follows the system default wherever it moves; this one moves only
//  when the player rebinds it (hogfollow.swift's `hal` measurement,
//  docs/future/bit-perfect-output.md).
//
//  The callback is a C function under the same realtime discipline as the
//  voice bus's render: plain memory and atomics, no lock, allocation,
//  Objective-C or dispatch call. It decides nothing. A gate the queue opens in
//  start and closes in stop says whether the proc is called at all; closed,
//  the callback writes silence, so a render that lands during a rebuild or
//  before the player is ready is silence, never a call into state being
//  changed. Every method here is player-queue confined except the two clock
//  reads.
//

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

// What the unit pulls: `frames` of the unit's format into `data`, one buffer
// per channel, on the IO thread under the callback's discipline, whatever
// count the device's cycle is. A status other than noErr is a dropout: the
// cycle is written as silence.
typedef OSStatus (*VibeOutputRenderProc)(void * _Nullable refCon, const AudioTimeStamp *timestamp, UInt32 frames,
                                         AudioBufferList *data) CA_REALTIME_API;

@interface AudioOutputUnit : NSObject

// A HALOutput instance with output enabled, input disabled and the callback
// installed. nil when the component cannot be instantiated.
- (nullable instancetype)init;

// The bound device: a field, never a HAL read; kAudioObjectUnknown before the
// first bind.
@property (nonatomic, readonly) AudioDeviceID deviceID;
// What the unit pulls at: the player's render format. nil until configured.
@property (nonatomic, readonly, nullable) AVAudioFormat *format;
// Between start and stop.
@property (nonatomic, readonly) BOOL running;
// Device plus stream latency and the safety offset, read at bind, in seconds.
@property (nonatomic, readonly) NSTimeInterval presentationLatency;
// For the report's channel-map read only.
@property (nonatomic, readonly) AudioUnit audioUnit;
// IO cycles the proc could not render, so silence was written. Cumulative.
@property (nonatomic, readonly) uint64_t dropouts;
// The callback's cost, for dump_health and a before/after measurement: the
// IO cycles the gate was open for, and the mean and the longest time spent
// inside the callback over them, in microseconds. Cumulative.
@property (nonatomic, readonly) uint64_t renderCycles;
@property (nonatomic, readonly) double renderMeanMicroseconds;
@property (nonatomic, readonly) double renderMaxMicroseconds;

// Stopped only. Sets kAudioOutputUnitProperty_CurrentDevice.
- (OSStatus)bindToDevice:(AudioDeviceID)deviceID;

// Stopped only: uninitialize, set the input stream format, remember the
// proc, initialize. refCon is the caller's to keep valid until the next
// configure or the unit's end.
- (BOOL)configureFormat:(AVAudioFormat *)format
             renderProc:(VibeOutputRenderProc)renderProc
                 refCon:(void * _Nullable)refCon
                  error:(NSError * _Nullable * _Nullable)error;

// Opens the gate, then starts the unit; a refused start closes it again.
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
// Closes the gate, stops the unit, and returns with no render inside the callback.
- (void)stop;


@end

NS_ASSUME_NONNULL_END

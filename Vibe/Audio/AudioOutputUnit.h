//
//  AudioOutputUnit.h
//  Vibe
//
//  One hosted output unit whose render callback pulls the player's render
//  proc into the hardware's buffers. macOS: a HALOutput unit bound to one
//  device, which — unlike a default output unit — moves only when the player
//  rebinds it. iOS: RemoteIO, whose route is the audio session's.
//
//  The callback runs under the voice bus's realtime discipline and decides
//  nothing: a gate opened in start and closed in stop says whether the proc is
//  called; closed, it writes silence, so a cycle during a rebuild never calls
//  into state being changed.
//
//  Every method is called on the player queue, records its effect at once (the
//  properties answer the state the unit is headed for) and queues the HAL work
//  on the unit's own serial queue in call order; only waitUntilIdle waits for
//  that queue. A stop closes the gate before it returns and
//  a superseded start never opens it, so the proc is never called on a unit
//  still at its previous device or format. Later refusals reach
//  `failureHandler`.
//

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#if TARGET_OS_OSX
#import <CoreAudio/CoreAudio.h>
#endif

NS_ASSUME_NONNULL_BEGIN

// What the unit pulls: `frames` of the unit's format into `data`, one buffer
// per channel, on the IO thread under the callback's discipline, whatever
// count the device's cycle is. A status other than noErr is a dropout: the
// cycle is written as silence.
typedef OSStatus (*VibeOutputRenderProc)(void * _Nullable refCon, const AudioTimeStamp *timestamp, UInt32 frames,
                                         AudioBufferList *data) CA_REALTIME_API;

@interface AudioOutputUnit : NSObject

// A HALOutput instance on macOS, RemoteIO on iOS, with output enabled, input
// disabled and the callback installed. nil when the component cannot be
// instantiated.
- (nullable instancetype)init;

#if TARGET_OS_OSX
// The device the last bind named: a field, never a HAL read;
// kAudioObjectUnknown before the first bind and after `forgetDevice`.
@property (nonatomic, readonly) AudioDeviceID deviceID;
#endif
// What the unit pulls at: the player's render format. nil until configured.
@property (nonatomic, readonly, nullable) AVAudioFormat *format;
// Between start and stop, as requested; the device may still be starting.
@property (nonatomic, readonly) BOOL running;
// Moved by every start and stop, from one counter every unit shares, so it
// names one start or stop of one unit. A failure carries the one its start
// was given, so the receiver can tell whether a later start or stop — or
// another unit — owns the output.
@property (nonatomic, readonly) uint64_t runGeneration;
// A start the HAL refused, or one made on a unit whose bind or configure it
// refused: the error, the start's runGeneration, and whether the bind was the
// refusal; called on the unit's queue, the gate already closed. On iOS also
// a started unit the system stopped itself, as an interruption does: no
// error, on whatever thread the unit reports it, the gate still open until
// the receiver stops the unit.
@property (atomic, copy, nullable) void (^failureHandler)(NSError * _Nullable error, uint64_t runGeneration, BOOL bindRefused);
// Device plus stream latency and the safety offset, in seconds; on iOS the
// session's output latency, read live, as the route's rate is before every
// start. TRAP: on macOS a field the unit's queue fills after each bind,
// configure and start (channelMap likewise), never a live read: a hung
// device held the player queue 30 s per HAL read.
@property (atomic, readonly) NSTimeInterval presentationLatency;
// The device's IO buffer at its nominal rate, in seconds — the cycle the
// unit renders ahead of the device — read as presentationLatency is; on iOS
// the session's IO buffer duration.
@property (atomic, readonly) NSTimeInterval bufferLatency;
// The unit's input channel map onto the device's stream, as its queue read it
// after the last bind or configure; nil before one, or when unreadable. For
// the bit-perfect report, which must not wait on the unit's queue.
@property (atomic, copy, readonly, nullable) NSArray<NSNumber *> *channelMap;
// IO cycles the proc could not render, so silence was written. Cumulative.
@property (nonatomic, readonly) uint64_t dropouts;
// The callback's cost over the cycles the gate was open, in microseconds.
// Cumulative.
@property (nonatomic, readonly) uint64_t renderCycles;
@property (nonatomic, readonly) double renderMeanMicroseconds;
@property (nonatomic, readonly) double renderMaxMicroseconds;
// Cycles whose callback outran the audio it rendered. Cumulative.
@property (nonatomic, readonly) uint64_t lateCycles;
// Cycles whose sample time did not follow the last one, and the frames the
// device's clock skipped ahead across them. Cumulative; a start is not a jump.
@property (nonatomic, readonly) uint64_t clockJumps;
@property (nonatomic, readonly) uint64_t skippedFrames;
// Zeroes all seven. Any thread; a cycle in flight lands in the new count.
- (void)clearCounters;

#if TARGET_OS_OSX
// Stopped only. Sets kAudioOutputUnitProperty_CurrentDevice on the unit's
// queue, so it never refuses at once: a refusal fails the next start.
- (void)bindToDevice:(AudioDeviceID)deviceID;
// The bind is known not to have landed: the next bind is never a no-op.
- (void)forgetDevice;
#endif

// Stopped only: uninitialize, set the input stream format, remember the
// proc, initialize. On macOS the HALOutput instance is replaced first and
// rebound to the last landed device, so it reads that device's current
// format. refCon is the caller's to keep valid until the next configure or
// the unit's end. A refusal fails the next start.
- (void)configureFormat:(AVAudioFormat *)format
             renderProc:(VibeOutputRenderProc)renderProc
                 refCon:(void * _Nullable)refCon;

// Asks the unit to start: its queue opens the gate, then starts the unit, and
// a refused start closes it again and reports through failureHandler.
- (void)start;
// Closes the gate, then has the unit stopped. The unit's own wait for a
// callback is bounded; the pipeline retains render state until that callback
// actually leaves.
- (void)stop;

// The iOS media-services reset: the instance died with the media server, and
// Apple's contract is to dispose it without messaging it. Stops the unit;
// from then on no queued start, configure or stop, even one queued before
// this, messages the instance, and the unit's end only disposes it.
- (void)markDead;

// Returns once every call made before it has reached the HAL. For a caller
// about to change the device's format or ownership, which must not overtake
// the stop it follows (a hogged device's format restored under a running
// output strands its next start with error 35). Never on the unit's queue.
- (void)waitUntilIdle;

@end

NS_ASSUME_NONNULL_END

//
//  AudioFX.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@class AVAudioFormat;

NS_ASSUME_NONNULL_BEGIN

// The DJ effects: the low-kill high-pass (Q, with a W boost) and the
// send-returns (E reverb, R and T ping-pong delays). Plain on-off state per
// effect; TransportKeyMonitor tells a tap from a hold. The FX segment of the
// render, between the bus and the meter:
//
//   bus -> lowKill -+-> dry -----------------------------------> out
//                   +-> reverb send -> reverb -> lowCut -------> +
//                   +-> 1/8 delay send  -> lanes -> pans -> sum -+-> lowCut -> +
//                   +-> 1/16 delay send -> lanes -> pans -> sum -+
//
// Apple's units (AUNBandEQ, MatrixReverb, AUDelay) do the DSP, rendered in
// place by VibeFXChainRender; gates, pans and sums are buffer math. A stage
// renders only while it has work and is reset and skipped otherwise, so idle
// effects cost nothing and dormant FX are sample-exact.
//
// Setters record lock-guarded intent and dispatch the work onto the player's
// queue; the gate targets and activity flags are atomics the audio thread
// reads. Hosting, connecting and disconnecting run on the queue with the
// output stopped. A hosting is one allocation the render is handed whole, so
// a re-host swaps it; a stage is reset, and a hosting freed, only once the
// render is outside it (`afterRenderLeaves`). The object exists from the
// player's synchronous init, so intent set before the first connect is kept.
@interface AudioFX : NSObject

// queue is the player's. scheduler is its scheduleAfterSeconds:block:, so the
// ramps ride the player's clock (the debug pump's under manual rendering).
// afterRenderLeaves runs `work` once no render is inside the pipeline; `work`
// captures plain pointers only.
- (instancetype)initWithQueue:(dispatch_queue_t)queue
                    scheduler:(void (^)(NSTimeInterval seconds, dispatch_block_t block))scheduler
            afterRenderLeaves:(void (^)(dispatch_block_t work))afterRenderLeaves;

// On the queue with the output stopped; idempotent. The units are hosted at
// the first connect (`format` stereo float32 non-interleaved) and kept; a
// connect at another rate re-hosts them and re-applies the intent.
// Disconnecting rests every unit and tail without changing intent.
- (void)setConnected:(BOOL)connected format:(nullable AVAudioFormat *)format maximumFrameCount:(UInt32)maximumFrameCount;

// Whether the segment is in the chain. Player-queue only.
@property (nonatomic, readonly) BOOL connected;

// Whether a send is in the render (gate open, or its declared tail still
// ringing), and the longest such tail, 0 while unhosted: the idle stop waits
// for a tail, at most that long. Player-queue only.
@property (nonatomic, readonly) BOOL sendsActive;
@property (nonatomic, readonly) NSTimeInterval longestTailSeconds;

// The current hosting, NULL while unhosted. A published chain stays valid for
// every render that read it. Player queue.
typedef struct VibeFXChain VibeFXChain;
- (VibeFXChain *)chain;

// Idle effects render nothing, which the tests read. Any thread.
- (NSUInteger)hostedUnitCount;
- (uint64_t)unitRenders;
// For the audio-path report. Player queue.
- (NSDictionary<NSString *, id> *)diagnosticSnapshot;

// Q: a resonant high-pass that cuts the bass; persists across tracks, and
// sweeps over ~80 ms so it never clicks. NO also clears lowKillBoostActive,
// which modifies this filter and must never outlive it.
@property (nonatomic) BOOL lowKillEnabled;

// W: the same high-pass at double the cutoff, whether or not lowKillEnabled
// is on; clearing it sweeps back to what lowKillEnabled implies.
@property (nonatomic) BOOL lowKillBoostActive;

// E: a long, fully wet, low-cut reverb return. NO cuts only the send; the
// tail rings out.
@property (nonatomic) BOOL reverbSendEnabled;

// R: a 1/8-note ping-pong echo with heavy feedback, high-passed. NO cuts only
// the send; the trail decays.
@property (nonatomic) BOOL delaySendEnabled;

// T: the same echo on 1/16-note taps; independent of R.
@property (nonatomic) BOOL shortDelaySendEnabled;

// The effective, pitch-scaled tempo the taps follow; 0 or less means unknown
// (120 BPM applies).
@property (nonatomic) float delayTapBPM;

@end

// In place over `io`: stereo float32, non-interleaved, at most the hosted
// maximumFrameCount frames. Audio thread. The first unit render that fails
// ends the call with its status; the caller silences the slice.
OSStatus VibeFXChainRender(VibeFXChain *chain, const AudioTimeStamp *timestamp, UInt32 frames, AudioBufferList *io) CA_REALTIME_API;

// The one hosting sequence the FX units and the varispeed share; `configure`
// runs before the initialize. NO, with nothing hosted, when any step is
// refused. Player queue, output stopped.
BOOL VibeHostAudioUnit(AudioUnit _Nullable * _Nonnull unit, OSType type, OSType subtype,
                       const AudioStreamBasicDescription *format, UInt32 maximumFrameCount,
                       AURenderCallbackStruct input, void (^ _Nullable configure)(AudioUnit));
// Uninitializes and disposes `*unit` when there is one, leaving NULL.
void VibeDisposeAudioUnit(AudioUnit _Nullable * _Nonnull unit);
// A unit's Float64 global property — latency, tail time — in seconds; 0 when
// unreadable.
double VibeAudioUnitSeconds(AudioUnit _Nullable unit, AudioUnitPropertyID property);

NS_ASSUME_NONNULL_END

//
//  AudioFX.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@class AVAudioFormat;

NS_ASSUME_NONNULL_BEGIN

// The DJ performance effects on the master bus: the low-kill high-pass, on Q
// with a W boost, and the send-returns — E for a reverb wash, R and T for
// ping-pong delays. A bare key drives each one, and the same key both taps and
// holds. TransportKeyMonitor owns that distinction; this class simply holds
// plain on-off state per effect.
//
// It owns the FX segment of the render pipeline, everything between the bus
// and the meter:
//
//   bus -> lowKill -+-> dry -----------------------------------> out
//                   +-> reverb send -> reverb -> lowCut -------> +
//                   +-> 1/8 delay send  -> lanes -> pans -> sum -+-> lowCut -> +
//                   +-> 1/16 delay send -> lanes -> pans -> sum -+
//
// Apple's units do the DSP — AUNBandEQ, MatrixReverb, AUDelay — hosted
// through the AudioUnit C API and rendered in place by VibeFXChainRender on
// the audio thread. The mixers the engine graph needed are buffer math: a
// gate is a gain the queue targets and the audio thread slews at the rate
// AVAudioMixerNode slewed its volume, a pan is that mixer's balance law, a
// sum is an add. A stage renders only while it has work — a gate open or a
// tail still ringing, the low kill on or settling after it parked — and is
// reset and skipped otherwise, so idle effects cost nothing and dormant FX
// are sample-exact.
//
// Threading mirrors AudioPlayer. Property setters record lock-guarded intent
// and dispatch the parameter work onto the player's serial queue, where the
// sweeps and gate ramps stay queue-confined; the gate targets and the
// activity flags are atomics the audio thread reads. Hosting, connecting,
// disconnecting and a format change run on the queue with the output stopped.
// A hosting is one allocation the render is handed whole — the units and the
// scratch at one format — so a re-host swaps it and a render still inside
// the old one finishes there; a stage is reset, and a hosting freed, only
// once the render has been seen outside it (the player's `afterRenderLeaves`),
// so no render is ever inside a unit being reset or torn down. The object is
// created before the pipeline exists, in AudioPlayer's synchronous init, so
// intent set early — a menu action or the BPM feed racing the async init — is
// never lost, and the first connect applies whatever was recorded.
@interface AudioFX : NSObject

// queue is the player's serial queue. Every mutation this class makes runs
// there. scheduler runs a block on that queue after a delay — the player's
// own scheduleAfterSeconds:block:, so the sweeps, gate ramps and tail windows
// ride whatever clock the player does (the debug pump's, under manual
// rendering). afterRenderLeaves runs `work` once no render is inside the
// pipeline — now, when the player sees the render outside, else when it next
// does — so a stage that left the render is reset, and a hosting the render
// left is freed, never under a render; `work` captures plain pointers only.
- (instancetype)initWithQueue:(dispatch_queue_t)queue
                    scheduler:(void (^)(NSTimeInterval seconds, dispatch_block_t block))scheduler
            afterRenderLeaves:(void (^)(dispatch_block_t work))afterRenderLeaves;

// Connects or disconnects the segment, on the queue with the output stopped.
// The units are hosted at the first connect, at `format` (stereo float32,
// non-interleaved) with `maximumFrameCount` the largest render, and kept
// across toggles; a connect at another rate re-hosts them and re-applies the
// recorded intent. Disconnecting resets every unit and tail without changing
// intent and reads no format; the caller clears intent before submitting a
// bypass. Both are idempotent.
- (void)setConnected:(BOOL)connected format:(nullable AVAudioFormat *)format maximumFrameCount:(UInt32)maximumFrameCount;

// Whether the segment is in the chain. Player-queue only.
@property (nonatomic, readonly) BOOL connected;

// The audio thread's view of the segment: the current hosting, NULL while
// unhosted. A chain the player published into the render stays valid for
// every render that read it, whatever replaced it since. Player queue.
typedef struct VibeFXChain VibeFXChain;
- (VibeFXChain *)chain;

// Hosted units alive, and renders they have done: idle effects render
// nothing, which the tests and the stress oracle read. Any thread.
- (NSUInteger)hostedUnitCount;
- (uint64_t)unitRenders;
// The segment as it stands — connection, hosting, rate, each stage's intent
// and activity — for the audio-path report. Player queue.
- (NSDictionary<NSString *, id> *)diagnosticSnapshot;

// DJ-style low kill on the Q key: a resonant high-pass filter on the master
// bus that cuts the bass. It is a deck control, so it persists across tracks
// and applies to whatever is playing or starts to play. Toggling sweeps the
// cutoff over about 80ms rather than switching instantly, so it never clicks.
//
// Setting this to NO also clears lowKillBoostActive, because the boost
// modifies this filter and must never outlive it.
@property (nonatomic) BOOL lowKillEnabled;

// The low kill's boost, on the W key. While YES the same high-pass runs at
// double the usual cutoff, whether or not lowKillEnabled is on, and clearing
// it sweeps back to whatever lowKillEnabled implies. It uses the same declick
// sweep as the toggle, and is subordinate to lowKillEnabled; see the note
// above.
@property (nonatomic) BOOL lowKillBoostActive;

// The reverb send, on the E key. While YES the master signal also feeds a
// long, fully wet reverb return, low-cut so the tail cannot muddy the bass.
// Setting NO cuts only the send, and the tail rings out naturally.
@property (nonatomic) BOOL reverbSendEnabled;

// The delay echo send, on the R key. While YES the master signal also feeds an
// 1/8-note ping-pong echo with aggressive feedback, high-passed so the repeats
// do not stack up bass. Setting NO cuts only the send, and the trail decays
// through the feedback naturally.
@property (nonatomic) BOOL delaySendEnabled;

// The short delay echo send, on the T key: the same ping-pong echo as
// delaySendEnabled, on 1/16-note taps, so twice as fast. The two are
// independent sends and can run together.
@property (nonatomic) BOOL shortDelaySendEnabled;

// The effective, pitch-scaled tempo in BPM that the echo's 1/8-note tap
// follows. The controller feeds it from the same tagged or detected BPM the
// label shows. A value of 0 or less means unknown, and a default of 120 BPM
// applies.
@property (nonatomic) float delayTapBPM;

@end

// The segment, in place over `io`: stereo float32, non-interleaved, at most
// the hosted maximumFrameCount frames. Audio thread; an idle stage costs
// nothing. The player calls it only while the segment is connected — a
// disconnected chain is not in the render at all — and a disconnected
// chain's stages are all at rest anyway, so the call changes nothing.
OSStatus VibeFXChainRender(VibeFXChain *chain, const AudioTimeStamp *timestamp, UInt32 frames, AudioBufferList *io) CA_REALTIME_API;

// Hosting one of Apple's units through the C API, the one sequence the FX
// units and the player's varispeed share: instantiate, the stream format on
// both scopes, the largest render, the input callback, `configure` before
// the initialize (for properties a unit takes only then), then the
// initialize. NO, with nothing hosted, when any step is refused. Player queue,
// with the output stopped.
BOOL VibeHostAudioUnit(AudioUnit _Nullable * _Nonnull unit, OSType type, OSType subtype,
                       const AudioStreamBasicDescription *format, UInt32 maximumFrameCount,
                       AURenderCallbackStruct input, void (^ _Nullable configure)(AudioUnit));
// Uninitializes and disposes `*unit` when there is one, leaving NULL.
void VibeDisposeAudioUnit(AudioUnit _Nullable * _Nonnull unit);
// A unit's Float64 global property — latency, tail time — in seconds; 0 when
// unreadable.
double VibeAudioUnitSeconds(AudioUnit _Nullable unit, AudioUnitPropertyID property);

NS_ASSUME_NONNULL_END

//
//  AudioFX.m
//  Vibe
//

#import "AudioFX.h"
#import "AudioFXMath.h" // the cutoff, tap and swell arithmetic, tested separately
#import "FadeMath.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

// The low-kill cutoffs and the default tap tempo are in AudioFXMath.h, with
// the functions that resolve them. The EQ runs two cascaded high-pass bands
// swept together, 12 dB/oct each for 24 dB/oct in total — a resonant one
// carrying a small DJ-filter bump at the cutoff, plus a plain 2nd-order
// Butterworth.
//
// Resonance of the resonant band, as AUNBandEQ bandwidth in octaves, where
// narrower is peakier. A touch of squelch at the cutoff, not a scream.
static const float kLowKillResonanceBandwidth = 0.7f;
// Sweep resolution, much finer than the volume fades. Coefficient jumps big
// enough to hear as zipper or click need small steps, and a slightly longer
// total sweep of about 80ms still reads as an instant kill.
static const int kLowKillSweepSteps = 40;
static const uint64_t kLowKillSweepStepMicroseconds = 2000;

// Momentary reverb send, on a held E key. The master signal is tapped
// post-low-kill into a gated, 100%-wet parallel reverb return, so releasing
// the key cuts the send while the tail rings out naturally. This gate level
// while engaged is the wet-dry balance, since the dry path always runs at
// unity, so anything below 0.5 keeps the verb sitting under the dry signal.
static const float kReverbSendLevel = 0.3f;
// High-pass on the reverb output, so the tail cannot muddy the bass.
// Filtering the return rather than the send guarantees that even the ringing
// tail is low-cut.
static const float kReverbTailLowCutHz = 550.0f;
#if TARGET_OS_OSX
// MatrixReverb tuning, applied on top of the Cathedral preset; Reverb2 sounds
// thin and digital by comparison. CAUTION: the ranges documented in
// AudioUnitParameters.h are stale. The AU's real LargeSize range, queried
// through kAudioUnitProperty_ParameterInfo, is 0.005-0.15, not the header's
// "0.4->10.0 Secs", and an out-of-range value asserts in the render thread
// through caulk CAVerboseAbort, killing the app on first play. MatrixReverb
// has no decay-seconds knob at all, so the size, mix and density maxed out
// below give the longest tail this engine does. Cathedral ships at LargeSize
// 0.06 and mix 35.
static const float kReverbLargeSize = 0.15f;     // the real max: the tail knob
static const float kReverbSmallLargeMix = 90.0f; // 0-100: mostly the large hall engine
static const float kReverbLargeDensity = 0.9f;   // lush, smooth tail
#endif

// Momentary delay echo sends, on held R and T keys, using the same gated
// send-return pattern as the reverb. The tap is a fraction of a beat of the
// effective, pitch-scaled tempo. The controller feeds delayTapBPM from the
// same tagged or detected BPM the label shows, and with no tempo known the
// default below applies. R and T are the same machine at different clock
// divisions:
static const float kDelayTapBeats = 0.5f;       // R: 1/8 note, half a beat
static const float kShortDelayTapBeats = 0.25f; // T: 1/16 note, a quarter beat
static const float kDelaySendLevel = 0.3f;
// Per-hop echo decay, where L->R counts as one hop. The ping-pong lanes run
// at twice the tap period, as the graph comment at the ivars explains, so each
// lane's own feedback is this squared.
static const float kDelayFeedbackPercent = 75.0f; // aggressive: a long trail of repeats
// High-pass on the delay output. Every repeat re-exits through it, so the
// echoes never pile up bass under the dry signal. AVAudioUnitDelay's own
// in-loop filter is lowpass-only, so the cut lives on the return instead.
static const float kDelayEchoLowCutHz = 450.0f;
// Ping-pong width: echoes alternate sides at half pan, not hard left and right.
static const float kDelayPingPongPan = 0.5f;

// After a send's fast open, it keeps swelling gently while the key stays held,
// so the effect builds the longer it is ridden, like easing a send fader up.
// The ratio multiplies the base level over six seconds, in steps small enough
// — about 0.5% each — to be seamless. Releasing the key still closes fast, on
// the normal fade cadence.
static const float kReverbSwellRatio = 1.8f; // 0.3 -> 0.54
static const float kDelaySwellRatio = 1.8f;  // 0.3 -> 0.54
static const int kSendSwellSteps = 120;
static const uint64_t kSendSwellStepMicroseconds = 50000; // 120 x 50ms = 6s

// One complete ping-pong delay send and return, built once per tap length, so
// that the 1/8-note (R) and 1/16-note (T) echoes are the same machine at
// different clock divisions. AVAudioEngine forbids feedback cycles, which
// makes the classic cross-fed ping-pong impossible. Instead two acyclic lanes
// run at twice the tap period T, with the left lane offset by T, and they
// interleave into an exact alternating pattern. All delays are 100% wet, with
// per-hop decay f:
//
//   gate -> half(T) ------------------> panLeft (-50%)   L: T
//           half -> left(2T,f^2) ------> panLeft          L: 3T, 5T ...
//   gate -> right(2T,f^2) ------------> panRight(+50%, volume f)
//                                                         R: 2T, 4T ...
//   panLeft/panRight -> sum -> lowCut -> masterMix
//
// The pan mixers exist because AVAudioUnitDelay does not adopt AVAudioMixing:
// only a mixer feeding another mixer can pan.
//
// The non-geometric decay is deliberate. The left lane's echoes at 3T, 5T and
// so on start at the lane's own first-tap level, because `left`'s first wet
// tap emerges at unity and panLeft cannot compensate: its bus 0 carries the T
// tap, which must stay at unity. So every odd hop from 3 onwards lands f^2
// hotter than a strict per-hop trail, about 1.8x at f=0.75, giving
// 1, f, 1, f^3, f^2, ... rather than 1, f, f^2, f^3, f^4. The result is a
// left-leaning surge on every second repeat rather than a smooth fade. It was
// auditioned and kept: it reads as bounce, not as a bug. A strict trail would
// need a gain stage — a small mixer at f^2 — between `left` and `sum`.
@interface VibeDelaySend : NSObject {
@public
    // The gate's ramp generation, passed by pointer into the shared stepper,
    // stepSendGateRamp:...counter:. It is queue-confined, like AudioFX's own
    // reverb counter. It is a public ivar rather than a property so that
    // &send->_rampGeneration is expressible, and the send lives for AudioFX's
    // lifetime, so the pointer cannot dangle.
    uint64_t _rampGeneration;
}
@property (nonatomic) float beatsPerTap; // 0.5 = 1/8 note, 0.25 = 1/16
@property (nonatomic, strong) AVAudioMixerNode *gate;
@property (nonatomic, strong) AVAudioUnitDelay *half;
@property (nonatomic, strong) AVAudioUnitDelay *left;
@property (nonatomic, strong) AVAudioUnitDelay *right;
@property (nonatomic, strong) AVAudioMixerNode *panLeft;
@property (nonatomic, strong) AVAudioMixerNode *panRight;
@property (nonatomic, strong) AVAudioMixerNode *sum;
@property (nonatomic, strong) AVAudioUnitEQ *lowCut;
@end

@implementation VibeDelaySend
@end

@implementation AudioFX {
    // The player's serial engine queue, shared rather than owned. All graph
    // and parameter mutation runs here, as every other engine touch in the app
    // does.
    dispatch_queue_t        _queue;
    // nil until installInEngine:. The appliers no-op before then, and the
    // install pass re-applies the recorded intent.
    AVAudioEngine           *_engine;
    // Guards the intent flags and delayTapBPM. The ramp generations are
    // queue-confined and need no lock.
    os_unfair_lock          _stateLock;

    // Master-bus low-kill high-pass; the class comment gives its place in the
    // graph. _lowKillEnabled and _lowKillBoostActive are lock-guarded and hold
    // the UI-readable intent. The ramp generation is queue-confined and lets a
    // re-toggle mid-sweep preempt the old sweep.
    AVAudioUnitEQ           *_lowKillEQ;
    BOOL                    _lowKillEnabled;
    BOOL                    _lowKillBoostActive;
    uint64_t                _lowKillRampGeneration;

    // Momentary reverb send and return, parallel to the master chain:
    // lowKillEQ -> sendGate, at outputVolume 0 or 1 -> reverb, 100% wet ->
    // tail low-cut EQ -> masterMix, which also carries the dry path to the
    // output. The enabled flag is lock-guarded intent, and the ramp
    // generation, queue-confined, preempts an in-flight gate fade.
    AVAudioMixerNode        *_masterMix;
    AVAudioMixerNode        *_reverbSendGate;
    AVAudioUnitReverb       *_reverb; // wraps MatrixReverb ('aufx'/'mrev')
    AVAudioUnitEQ           *_reverbLowCut;
    BOOL                    _reverbSendEnabled;
    uint64_t                _reverbSendRampGeneration;

    // Momentary ping-pong delay sends, with parallel returns beside the
    // reverb's: one VibeDelaySend per tap length, whose class comment gives
    // the topology. _delayTapBPM, lock-guarded, is the effective tempo both
    // taps follow.
    VibeDelaySend           *_delayEighth;    // R key: 1/8-note taps
    VibeDelaySend           *_delaySixteenth; // T key: 1/16-note taps
    BOOL                    _delaySendEnabled;
    BOOL                    _shortDelaySendEnabled;
    float                   _delayTapBPM;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _queue = queue;
        _stateLock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

#pragma mark - Graph construction

- (AVAudioNode *)masterBusOutputNode {
    return _masterMix;
}

- (void)installInEngine:(AVAudioEngine *)engine {
    _engine = engine;

    // Master-bus low kill: mainMixer -> EQ -> and so on. The explicit connects
    // below replace the implicit mixer-to-output one. Both bands stay live for
    // the engine's lifetime, never bypassed (see kLowKillParkedHz), parked
    // inaudibly at 20 Hz, and the controls only sweep the cutoff through
    // applyLowKillTargetOnQueue. The output node converts if a later device
    // runs at a different sample rate from this format.
    _lowKillEQ = [[AVAudioUnitEQ alloc] initWithNumberOfBands:2];
    AVAudioUnitEQFilterParameters *resonantBand = _lowKillEQ.bands[0];
    resonantBand.filterType = AVAudioUnitEQFilterTypeResonantHighPass;
    resonantBand.bandwidth = kLowKillResonanceBandwidth;
    AVAudioUnitEQFilterParameters *plainBand = _lowKillEQ.bands[1];
    plainBand.filterType = AVAudioUnitEQFilterTypeHighPass;
    for (AVAudioUnitEQFilterParameters *band in _lowKillEQ.bands) {
        band.frequency = kLowKillParkedHz;
        band.bypass = NO;
    }
    [engine attachNode:_lowKillEQ];

    // Momentary reverb send and return; the ivar comment gives the graph.
    // masterMix exists so that the returns have somewhere to re-enter other
    // than mainMixer, where they would loop each effect back into its own
    // send. The gate rests closed, at volume 0, and the reverb is fully wet.
    // The dry signal only ever travels the masterMix path, so opening the gate
    // adds reverb on top.
    _masterMix = [[AVAudioMixerNode alloc] init];
    _reverbSendGate = [[AVAudioMixerNode alloc] init];
    // AVAudioUnitReverb wraps MatrixReverb (component description
    // 'aufx'/'mrev'), so the raw kReverbParam_* knobs are settable through its
    // audioUnit below. Hosting the AU directly through
    // AVAudioUnitEffect instead asserts in the render thread on the first
    // pull, in caulk CAVerboseAbort inside AudioUnitRender, because the
    // AVAudioUnitReverb wrapper applies configuration the raw hosting path
    // does not. Do not "simplify" back to AVAudioUnitEffect.
    _reverb = [[AVAudioUnitReverb alloc] init];
    [_reverb loadFactoryPreset:AVAudioUnitReverbPresetCathedral];
    _reverb.wetDryMix = 100;
    _reverbLowCut = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
    AVAudioUnitEQFilterParameters *tailCut = _reverbLowCut.bands.firstObject;
    tailCut.filterType = AVAudioUnitEQFilterTypeHighPass;
    tailCut.frequency = kReverbTailLowCutHz;
    tailCut.bypass = NO;
    [engine attachNode:_masterMix];
    [engine attachNode:_reverbSendGate];
    [engine attachNode:_reverb];
    [engine attachNode:_reverbLowCut];
    // Cathedral is the base character, and these push the tail out to the
    // target length. See the constants. macOS-only: there AVAudioUnitReverb
    // wraps MatrixReverb ('mrev'), whose raw kReverbParam_* knobs these are;
    // on iOS it wraps Reverb2, which has no equivalents, so iOS keeps the
    // plain Cathedral tail.
#if TARGET_OS_OSX
    AudioUnit reverbUnit = _reverb.audioUnit;
    AudioUnitSetParameter(reverbUnit, kReverbParam_SmallLargeMix, kAudioUnitScope_Global, 0, kReverbSmallLargeMix, 0);
    AudioUnitSetParameter(reverbUnit, kReverbParam_LargeSize, kAudioUnitScope_Global, 0, kReverbLargeSize, 0);
    AudioUnitSetParameter(reverbUnit, kReverbParam_LargeDensity, kAudioUnitScope_Global, 0, kReverbLargeDensity, 0);
#endif

    // Two ping-pong delay returns, the same machine at different clock
    // divisions; see VibeDelaySend. They are created and attached here so that
    // their gates exist as fan-out targets below, but wired after the fan-out,
    // so the dry path's explicit claim on masterMix bus 0 cannot disconnect a
    // return that grabbed bus 0 first.
    _delayEighth = [self createDelaySendWithBeatsPerTap:kDelayTapBeats engine:engine];
    _delaySixteenth = [self createDelaySendWithBeatsPerTap:kShortDelayTapBeats engine:engine];

    AVAudioFormat *mixerFormat = [engine.mainMixerNode outputFormatForBus:0];
    [engine connect:engine.mainMixerNode to:_lowKillEQ format:mixerFormat];
    // One-to-many: the post-low-kill master signal feeds the dry path, on
    // masterMix bus 0, and every send tap in parallel.
    [engine connect:_lowKillEQ
        toConnectionPoints:@[
            [[AVAudioConnectionPoint alloc] initWithNode:_masterMix bus:0],
            [[AVAudioConnectionPoint alloc] initWithNode:_reverbSendGate bus:0],
            [[AVAudioConnectionPoint alloc] initWithNode:_delayEighth.gate bus:0],
            [[AVAudioConnectionPoint alloc] initWithNode:_delaySixteenth.gate bus:0],
        ]
               fromBus:0
                format:mixerFormat];
    [engine connect:_reverbSendGate to:_reverb format:mixerFormat];
    [engine connect:_reverb to:_reverbLowCut format:mixerFormat];
    // connect:to:format: routes to a mixer's next available input bus, so the
    // returns land on buses 1 to 3, after the dry path's bus 0.
    [engine connect:_reverbLowCut to:_masterMix format:mixerFormat];
    [self wireDelaySend:_delayEighth engine:engine format:mixerFormat];
    [self wireDelaySend:_delaySixteenth engine:engine format:mixerFormat];
    [engine connect:_masterMix to:engine.outputNode format:mixerFormat];
    // Set mixer state only after the nodes are attached and wired.
    // AVAudioMixerNode's underlying mixer AU does not exist until then, and a
    // volume or pan written earlier is dropped: the gates would come up at
    // their default of 1.0 and the app would launch with the effects audibly
    // stuck on. The delay sends' gate and pan state is set the same way, at
    // the end of wireDelaySend:.
    _reverbSendGate.outputVolume = 0;

    // Apply any intent recorded before the engine existed: a key or menu
    // action racing the async engine init, or the controller's first BPM feed.
    [self applyLowKillTargetOnQueue];
    [self applyDelayTapOnQueue];
    os_unfair_lock_lock(&_stateLock);
    BOOL reverbOn = _reverbSendEnabled;
    BOOL delayOn = _delaySendEnabled;
    BOOL shortDelayOn = _shortDelaySendEnabled;
    os_unfair_lock_unlock(&_stateLock);
    if (reverbOn) {
        [self applySendGateOnQueue:_reverbSendGate enabled:YES
                             level:kReverbSendLevel swellRatio:kReverbSwellRatio
                           counter:&_reverbSendRampGeneration];
    }
    if (delayOn) {
        [self applyDelaySend:_delayEighth enabledOnQueue:YES];
    }
    if (shortDelayOn) {
        [self applyDelaySend:_delaySixteenth enabledOnQueue:YES];
    }
}

// Allocates, configures and attaches one ping-pong return's nodes, with no
// connections yet; see the wiring note in installInEngine:. It is fully wet
// like the reverb, so the dry path never runs through it and the gate only
// adds echoes on top. Tap times follow delayTapBPM, and lane feedback is the
// per-hop decay squared, because each lane repeats every two hops.
- (VibeDelaySend *)createDelaySendWithBeatsPerTap:(float)beatsPerTap engine:(AVAudioEngine *)engine {
    float laneFeedbackPercent = VibeDelayLaneFeedbackPercent(kDelayFeedbackPercent);
    // No tempo yet, so this is the default tap; applyDelayTapOnQueue restates
    // both times from the real one the moment the controller feeds it.
    NSTimeInterval defaultTap = VibeDelayTapSeconds(0, beatsPerTap);
    VibeDelaySend *send = [[VibeDelaySend alloc] init];
    send.beatsPerTap = beatsPerTap;
    send.gate = [[AVAudioMixerNode alloc] init];
    send.half = [[AVAudioUnitDelay alloc] init];
    send.half.wetDryMix = 100;
    send.half.feedback = 0; // pure T offset, no repeats of its own
    send.half.delayTime = defaultTap;
    send.left = [[AVAudioUnitDelay alloc] init];
    send.right = [[AVAudioUnitDelay alloc] init];
    for (AVAudioUnitDelay *lane in @[send.left, send.right]) {
        lane.wetDryMix = 100;
        lane.feedback = laneFeedbackPercent;
        lane.delayTime = VibeDelayLaneSeconds(0, beatsPerTap);
    }
    send.panLeft = [[AVAudioMixerNode alloc] init];
    send.panRight = [[AVAudioMixerNode alloc] init];
    send.sum = [[AVAudioMixerNode alloc] init];
    send.lowCut = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
    AVAudioUnitEQFilterParameters *echoCut = send.lowCut.bands.firstObject;
    echoCut.filterType = AVAudioUnitEQFilterTypeHighPass;
    echoCut.frequency = kDelayEchoLowCutHz;
    echoCut.bypass = NO;
    [engine attachNode:send.gate];
    [engine attachNode:send.half];
    [engine attachNode:send.left];
    [engine attachNode:send.right];
    [engine attachNode:send.panLeft];
    [engine attachNode:send.panRight];
    [engine attachNode:send.sum];
    [engine attachNode:send.lowCut];
    return send;
}

// Wires one return's internal chain, whose topology VibeDelaySend's comment
// gives, and lands it on masterMix's next available input bus. The gate and
// the half-tap delay each fan out one-to-many.
- (void)wireDelaySend:(VibeDelaySend *)send engine:(AVAudioEngine *)engine format:(AVAudioFormat *)format {
    [engine connect:send.gate
        toConnectionPoints:@[
            [[AVAudioConnectionPoint alloc] initWithNode:send.half bus:0],
            [[AVAudioConnectionPoint alloc] initWithNode:send.right bus:0],
        ]
               fromBus:0
                format:format];
    [engine connect:send.half
        toConnectionPoints:@[
            [[AVAudioConnectionPoint alloc] initWithNode:send.panLeft bus:0],
            [[AVAudioConnectionPoint alloc] initWithNode:send.left bus:0],
        ]
               fromBus:0
                format:format];
    [engine connect:send.left to:send.panLeft format:format]; // bus 1
    [engine connect:send.right to:send.panRight format:format];
    [engine connect:send.panLeft to:send.sum format:format];
    [engine connect:send.panRight to:send.sum format:format];
    [engine connect:send.sum to:send.lowCut format:format];
    [engine connect:send.lowCut to:_masterMix format:format];
    // Mixer state only after attaching and wiring; see the note in
    // installInEngine:.
    send.gate.outputVolume = 0;
    send.panLeft.pan = -kDelayPingPongPan;
    send.panRight.pan = kDelayPingPongPan;
    // One hop of decay on the right lane, whose first tap lands at 2T, hop 2,
    // a full hop after the left lane's T. The left lane's later echoes get no
    // such compensation, which is deliberate; see the non-geometric decay note
    // in VibeDelaySend's topology comment.
    send.panRight.outputVolume = kDelayFeedbackPercent / 100.0f;
}

#pragma mark - Low kill

- (BOOL)lowKillEnabled {
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _lowKillEnabled;
    os_unfair_lock_unlock(&_stateLock);
    return enabled;
}

- (void)setLowKillEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&_stateLock);
    if (_lowKillEnabled == enabled) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _lowKillEnabled = enabled;
    // The boost modifies the low kill rather than being a control of its own,
    // so killing the filter kills the boost with it. Otherwise a latched W
    // would hold the cutoff above where Q alone would put it while the low
    // kill read off. It is cleared under the same lock, so the one sweep below
    // resolves both rather than racing a second one.
    if (!enabled) {
        _lowKillBoostActive = NO;
    }
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applyLowKillTargetOnQueue];
    });
}

- (BOOL)lowKillBoostActive {
    os_unfair_lock_lock(&_stateLock);
    BOOL active = _lowKillBoostActive;
    os_unfair_lock_unlock(&_stateLock);
    return active;
}

- (void)setLowKillBoostActive:(BOOL)active {
    os_unfair_lock_lock(&_stateLock);
    if (_lowKillBoostActive == active) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _lowKillBoostActive = active;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applyLowKillTargetOnQueue];
    });
}

// Runs on _queue. It resolves the single cutoff both controls share — the held
// boost, at double cutoff, outranks the Q toggle, which outranks parked — and
// sweeps there from wherever the filter currently sits. A re-toggle or release
// mid-sweep bumps the generation, preempting the old sweep, and starts from
// the current frequency, so there is no jump. Bypass is never touched after
// installInEngine: un-bypasses the bands once: flipping it dumps stale
// delay-line state into the signal, an audible click (see kLowKillParkedHz).
// "Off" is purely the cutoff parked below the audible band.
- (void)applyLowKillTargetOnQueue {
    // TRAP: the guard is the NODE, never _engine. installInEngine: publishes
    // _engine as its first statement and mints the nodes further down, so an
    // _engine guard is already open over the window it claims to close.
    if (!_lowKillEQ) {
        return; // Not installed yet. installInEngine: re-applies it.
    }
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _lowKillEnabled;
    BOOL boost = _lowKillBoostActive;
    os_unfair_lock_unlock(&_stateLock);
    float target = VibeLowKillCutoffHz(enabled, boost);
    uint64_t generation = ++_lowKillRampGeneration;
    [self stepLowKillRamp:1 from:_lowKillEQ.bands.firstObject.frequency
                       to:target generation:generation];
}

// The fade-loop pattern applied to the filter cutoff. Both cascaded bands
// track the same frequency, stepped along a log-frequency curve —
// multiplicative interpolation, as in the volume fades — at the finer low-kill
// cadence.
- (void)stepLowKillRamp:(int)step from:(float)start to:(float)target generation:(uint64_t)generation {
    if (generation != _lowKillRampGeneration) {
        return; // A newer toggle owns the cutoff now.
    }
    float frequency = (step >= kLowKillSweepSteps)
            ? target
            : start * powf(target / start, (float)step / (float)kLowKillSweepSteps);
    for (AVAudioUnitEQFilterParameters *band in _lowKillEQ.bands) {
        band.frequency = frequency;
    }
    if (step >= kLowKillSweepSteps) {
        return;
    }
    __weak AudioFX *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLowKillSweepStepMicroseconds * NSEC_PER_USEC)), _queue, ^{
        [weakSelf stepLowKillRamp:step + 1 from:start to:target generation:generation];
    });
}

#pragma mark - Reverb send

- (BOOL)reverbSendEnabled {
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _reverbSendEnabled;
    os_unfair_lock_unlock(&_stateLock);
    return enabled;
}

- (void)setReverbSendEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&_stateLock);
    if (_reverbSendEnabled == enabled) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _reverbSendEnabled = enabled;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applySendGateOnQueue:self->_reverbSendGate enabled:enabled
                             level:kReverbSendLevel swellRatio:kReverbSwellRatio
                           counter:&self->_reverbSendRampGeneration];
    });
}

// Runs on _queue. Opens or closes a send gate. Opening is a fast fade on the
// volume-fade cadence — an instant volume step clicks, whereas
// kFadeDurationMilliseconds does not — followed, while the gate stays open, by
// a slow swell up to swellRatio times the base level. Closing cuts only the
// send: the effect keeps rendering, so its tail decays naturally. A re-toggle
// mid-ramp preempts through the counter and continues from the current gate
// level.
- (void)applySendGateOnQueue:(AVAudioMixerNode *)gate enabled:(BOOL)enabled level:(float)level swellRatio:(float)swellRatio counter:(uint64_t *)counter {
    // The gate, not _engine: see the trap at applyDelayTapOnQueue. The gate is
    // what this ramps, and it is the thing that may not exist yet.
    if (!gate) {
        return; // Not installed yet. installInEngine: re-applies it.
    }
    uint64_t generation = ++(*counter);
    if (!enabled) {
        [self stepSendGateRamp:gate step:1 of:kFadeSteps stepMicroseconds:kFadeStepMicroseconds
                          from:gate.outputVolume to:0
                    generation:generation counter:counter completion:nil];
        return;
    }
    __weak AudioFX *weakSelf = self;
    [self stepSendGateRamp:gate step:1 of:kFadeSteps stepMicroseconds:kFadeStepMicroseconds
                      from:gate.outputVolume to:level
                generation:generation counter:counter completion:^{
        // The same generation is used, so the release or re-press that would
        // invalidate the swell bumps the counter and the first swell step
        // drops out.
        [weakSelf stepSendGateRamp:gate step:1 of:kSendSwellSteps stepMicroseconds:kSendSwellStepMicroseconds
                              from:level to:VibeSendSwellLevel(level, swellRatio)
                        generation:generation counter:counter completion:nil];
    }];
}

// counter points at the owning send's queue-confined ramp-generation ivar, so
// the two sends preempt independently. It is dereferenced only while self is
// alive, since the method runs on a strong self, so the pointer cannot dangle.
// The completion fires only on an un-preempted run to the target: a preempted
// ramp's owner has moved on, and its follow-up must not start.
- (void)stepSendGateRamp:(AVAudioMixerNode *)gate step:(int)step of:(int)steps stepMicroseconds:(uint64_t)stepMicroseconds from:(float)start to:(float)target generation:(uint64_t)generation counter:(uint64_t *)counter completion:(dispatch_block_t)completion {
    if (generation != *counter) {
        return; // A newer toggle owns the gate now.
    }
    if (step >= steps) {
        gate.outputVolume = target;
        if (completion) {
            completion();
        }
        return;
    }
    gate.outputVolume = VibeFadeVolumeOverSteps(start, target, step, steps);
    __weak AudioFX *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stepMicroseconds * NSEC_PER_USEC)), _queue, ^{
        [weakSelf stepSendGateRamp:gate step:step + 1 of:steps stepMicroseconds:stepMicroseconds from:start to:target generation:generation counter:counter completion:completion];
    });
}

#pragma mark - Delay send

- (BOOL)delaySendEnabled {
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _delaySendEnabled;
    os_unfair_lock_unlock(&_stateLock);
    return enabled;
}

- (void)setDelaySendEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&_stateLock);
    if (_delaySendEnabled == enabled) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _delaySendEnabled = enabled;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applyDelaySend:self->_delayEighth enabledOnQueue:enabled];
    });
}

- (BOOL)shortDelaySendEnabled {
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _shortDelaySendEnabled;
    os_unfair_lock_unlock(&_stateLock);
    return enabled;
}

- (void)setShortDelaySendEnabled:(BOOL)enabled {
    os_unfair_lock_lock(&_stateLock);
    if (_shortDelaySendEnabled == enabled) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _shortDelaySendEnabled = enabled;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applyDelaySend:self->_delaySixteenth enabledOnQueue:enabled];
    });
}

// Runs on _queue. Both delay sends share the level and swell tuning; only the
// gate, and its generation counter, differ.
- (void)applyDelaySend:(VibeDelaySend *)send enabledOnQueue:(BOOL)enabled {
    if (!send) {
        return; // Not installed yet. installInEngine: re-applies it.
    }
    [self applySendGateOnQueue:send.gate enabled:enabled
                         level:kDelaySendLevel swellRatio:kDelaySwellRatio
                       counter:&send->_rampGeneration];
}

- (float)delayTapBPM {
    os_unfair_lock_lock(&_stateLock);
    float bpm = _delayTapBPM;
    os_unfair_lock_unlock(&_stateLock);
    return bpm;
}

- (void)setDelayTapBPM:(float)bpm {
    os_unfair_lock_lock(&_stateLock);
    if (_delayTapBPM == bpm) {
        os_unfair_lock_unlock(&_stateLock);
        return; // Called on every fader tick, so only real changes touch the queue.
    }
    _delayTapBPM = bpm;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applyDelayTapOnQueue];
    });
}

// Runs on _queue. The delays sit post-varispeed, so tap time is wall-clock and
// matches the effective, pitch-scaled tempo the controller provides. Each
// send's lanes run at twice its tap; see the topology comment.
// AVAudioUnitDelay caps delayTime at two seconds, so the 1/8-note send's lanes
// pin there below an effective 30 BPM, well beyond any real tempo.
- (void)applyDelayTapOnQueue {
    // TRAP: the guard is the SENDS, never _engine — and here it is load-bearing
    // rather than merely tidy. installInEngine: publishes _engine as its first
    // statement and mints the sends further down, so an _engine guard leaves
    // that window open, and the array literal below raises on a nil element.
    if (!_delayEighth || !_delaySixteenth) {
        return; // Not installed yet. installInEngine: re-applies it.
    }
    os_unfair_lock_lock(&_stateLock);
    float bpm = _delayTapBPM;
    os_unfair_lock_unlock(&_stateLock);
    for (VibeDelaySend *send in @[_delayEighth, _delaySixteenth]) {
        NSTimeInterval lane = VibeDelayLaneSeconds(bpm, send.beatsPerTap);
        send.half.delayTime = VibeDelayTapSeconds(bpm, send.beatsPerTap);
        send.left.delayTime = lane;
        send.right.delayTime = lane;
    }
}

@end

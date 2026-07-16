//
//  AudioFX.m
//  Vibe
//

#import "AudioFX.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

// Fast-fade cadence, mirroring AudioPlayer's volume fades (25ms, 10 steps x
// 2.5ms, multiplicative/perceptually log) so a send gate opens exactly as
// fast as a pause fades.
static const int kFadeSteps = 10;
static const uint64_t kFadeStepMicroseconds = 2500;
static const float kFadeFloor = 0.001f; // -60 dB

static float VibeFadeVolume(float from, float to, int step) {
    if (step >= kFadeSteps) {
        return to;
    }
    float f = MAX(from, kFadeFloor);
    float t = MAX(to, kFadeFloor);
    return f * powf(t / f, (float)step / (float)kFadeSteps);
}

// Low-kill high-pass cutoff (engaged) — bass and kick gone, mids untouched.
// The EQ runs TWO cascaded high-pass bands swept together (12 dB/oct each,
// 24 dB/oct total): a resonant one carrying a small DJ-filter bump at the
// cutoff, plus a plain 2nd-order Butterworth.
static const float kLowKillCutoffHz = 200.0f;
// Held W drives the same filter to double the toggle's cutoff (400 Hz) —
// a momentary harder kill that releases back to the Q state.
static const float kLowKillBoostMultiplier = 2.0f;
// Parked (disengaged) cutoff: AUNBandEQ's frequency floor, below the audible
// band, so the filter is inaudible while parked. The bands are NEVER bypassed
// — un-bypassing a band dumps its stale delay-line state into the signal (an
// audible click), so on/off is purely a cutoff sweep between these two.
static const float kLowKillParkedHz = 20.0f;
// Resonance of the resonant band, as AUNBandEQ bandwidth in octaves
// (narrower = peakier). A touch of squelch at the cutoff, not a scream.
static const float kLowKillResonanceBandwidth = 0.7f;
// Sweep resolution: much finer than the volume fades — coefficient jumps big
// enough to hear (zipper/click) need small steps, and a slightly longer total
// sweep (~80ms) still reads as an instant kill.
static const int kLowKillSweepSteps = 40;
static const uint64_t kLowKillSweepStepMicroseconds = 2000;

// Momentary reverb send (held E key): the master signal is tapped post-low-kill
// into a gated 100%-wet parallel reverb return, so releasing the key cuts the
// SEND while the tail rings out naturally. Gate level while engaged — this IS
// the wet/dry balance (the dry path always runs at unity), so <0.5 keeps the
// verb sitting under the dry signal.
static const float kReverbSendLevel = 0.3f;
// High-pass on the reverb OUTPUT so the tail can't muddy the bass — filtering
// the return (not the send) guarantees even the ringing tail is low-cut.
static const float kReverbTailLowCutHz = 550.0f;
// MatrixReverb tuning, applied on top of the Cathedral preset (Reverb2 was
// tried first and sounded thin/digital). CAUTION: the ranges documented in
// AudioUnitParameters.h are STALE — the AU's real LargeSize range (queried
// via kAudioUnitProperty_ParameterInfo) is 0.005-0.15, not the header's
// "0.4->10.0 Secs", and an out-of-range value ASSERTS in the render thread
// (caulk CAVerboseAbort), killing the app on first play. MatrixReverb has no
// decay-seconds knob at all; size/mix/density maxed out below is the longest
// tail this engine does (Cathedral ships at LargeSize 0.06, mix 35).
static const float kReverbLargeSize = 0.15f;     // real max — the tail knob
static const float kReverbSmallLargeMix = 90.0f; // 0-100: mostly the large (hall) engine
static const float kReverbLargeDensity = 0.9f;   // lush, smooth tail

// Momentary delay echo send (held R key), the same gated send/return pattern
// as the reverb. The tap is an 1/8 note of the EFFECTIVE (pitch-scaled) tempo
// — the controller feeds delayTapBPM from the same tagged/detected BPM the
// label shows; with no tempo known the default below applies.
static const float kDelaySendLevel = 0.3f;
// Per-HOP echo decay (L->R counts as one hop). The ping-pong lanes run at
// twice the tap period (see the graph comment at the ivars), so each lane's
// own feedback is this squared.
static const float kDelayFeedbackPercent = 75.0f; // aggressive — a long trail of repeats
// High-pass on the delay OUTPUT: every repeat re-exits through it, so the
// echoes never pile up bass under the dry signal. (AVAudioUnitDelay's own
// in-loop filter is lowpass-only, so the cut lives on the return instead.)
static const float kDelayEchoLowCutHz = 450.0f;
static const float kDelayDefaultBPM = 120.0f; // 0.25s tap until a real tempo arrives
// Ping-pong width: echoes alternate sides at half pan, not hard L/R.
static const float kDelayPingPongPan = 0.5f;

// After a send's fast open, it keeps swelling gently while the key stays
// held — the effect builds the longer it's ridden, like easing a send fader
// up. Ratio x base level over 6s, in steps small enough (~0.5% each) to be
// seamless; releasing the key still closes fast on the normal fade cadence.
static const float kReverbSwellRatio = 1.8f; // 0.3 -> 0.54
static const float kDelaySwellRatio = 1.8f;  // 0.3 -> 0.54
static const int kSendSwellSteps = 120;
static const uint64_t kSendSwellStepMicroseconds = 50000; // 120 x 50ms = 6s

@implementation AudioFX {
    // The player's serial engine queue (shared, not owned): all graph and
    // parameter mutation runs here, like every other engine touch in the app.
    dispatch_queue_t        _queue;
    // nil until installInEngine: — the appliers no-op before then and the
    // install pass re-applies the recorded intent.
    AVAudioEngine           *_engine;
    // Guards the intent flags and delayTapBPM (the ramp generations are
    // queue-confined and need no lock).
    os_unfair_lock          _stateLock;

    // Master-bus low-kill high-pass — see the class comment for its place in
    // the graph. _lowKillEnabled/_lowKillBoostActive (lock-guarded) are the
    // UI-readable intent; the ramp generation (queue-confined) lets a
    // re-toggle mid-sweep preempt the old sweep.
    AVAudioUnitEQ           *_lowKillEQ;
    BOOL                    _lowKillEnabled;
    BOOL                    _lowKillBoostActive;
    uint64_t                _lowKillRampGeneration;

    // Momentary reverb send/return, parallel to the master chain:
    // lowKillEQ -> sendGate (outputVolume 0/1) -> reverb (100% wet) -> tail
    // low-cut EQ -> masterMix, where masterMix also carries the dry path to
    // the output. The enabled flag is lock-guarded intent, the ramp
    // generation (queue-confined) preempts an in-flight gate fade.
    AVAudioMixerNode        *_masterMix;
    AVAudioMixerNode        *_reverbSendGate;
    AVAudioUnitReverb       *_reverb; // wraps MatrixReverb ('aufx'/'mrev')
    AVAudioUnitEQ           *_reverbLowCut;
    BOOL                    _reverbSendEnabled;
    uint64_t                _reverbSendRampGeneration;

    // Momentary ping-pong delay send, a second parallel return next to the
    // reverb's. AVAudioEngine forbids feedback cycles, so the classic
    // cross-fed ping-pong is impossible — instead two acyclic lanes at TWICE
    // the tap period T, the left lane offset by T, interleave into an exact
    // alternating pattern (all delays 100% wet, per-hop decay f):
    //
    //   gate -> delayHalf(T) ------------------> panLeft (-50%)   L: T
    //           delayHalf -> delayLeft(2T,f^2) -> panLeft         L: 3T, 5T ...
    //   gate -> delayRight(2T,f^2) ------------> panRight(+50%, volume f)
    //                                                             R: 2T, 4T ...
    //   panLeft/panRight -> delaySum -> delayLowCut -> masterMix
    //
    // The pan mixers exist because AVAudioUnitDelay doesn't adopt
    // AVAudioMixing — only a mixer feeding another mixer can pan.
    // _delayTapBPM (lock-guarded) is the effective tempo the 1/8-note tap
    // follows.
    AVAudioMixerNode        *_delaySendGate;
    AVAudioUnitDelay        *_delayHalf;
    AVAudioUnitDelay        *_delayLeft;
    AVAudioUnitDelay        *_delayRight;
    AVAudioMixerNode        *_delayPanLeft;
    AVAudioMixerNode        *_delayPanRight;
    AVAudioMixerNode        *_delaySum;
    AVAudioUnitEQ           *_delayLowCut;
    BOOL                    _delaySendEnabled;
    uint64_t                _delaySendRampGeneration;
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

- (void)installInEngine:(AVAudioEngine *)engine {
    _engine = engine;

    // Master-bus low kill: mainMixer -> EQ -> ... (the explicit connects
    // below replace the implicit mixer->output one). Both bands stay live
    // (never bypassed — see kLowKillParkedHz) for the engine's lifetime,
    // parked inaudibly at 20 Hz; the controls only sweep the cutoff
    // (applyLowKillTargetOnQueue). The output node converts if a later
    // device runs at a different sample rate than this format.
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

    // Momentary reverb send/return (see the ivar comment for the graph).
    // masterMix exists so the returns have somewhere to re-enter that isn't
    // mainMixer — returning there would loop each effect back into its own
    // send. The gate rests closed (volume 0) and the reverb is fully wet:
    // the dry signal only ever travels the masterMix path, so opening the
    // gate ADDS reverb on top.
    _masterMix = [[AVAudioMixerNode alloc] init];
    _reverbSendGate = [[AVAudioMixerNode alloc] init];
    // AVAudioUnitReverb wraps MatrixReverb (verified: its component
    // description is 'aufx'/'mrev'), so the raw kReverbParam_* knobs are
    // settable through its audioUnit below. Hosting the AU directly via
    // AVAudioUnitEffect instead ASSERTS in the render thread on the first
    // pull (caulk CAVerboseAbort inside AudioUnitRender) — the
    // AVAudioUnitReverb wrapper applies configuration the raw hosting path
    // doesn't. Don't "simplify" back to AVAudioUnitEffect.
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
    // Cathedral is the base character; these push the tail out to the
    // target length (see the constants).
    AudioUnit reverbUnit = _reverb.audioUnit;
    AudioUnitSetParameter(reverbUnit, kReverbParam_SmallLargeMix, kAudioUnitScope_Global, 0, kReverbSmallLargeMix, 0);
    AudioUnitSetParameter(reverbUnit, kReverbParam_LargeSize, kAudioUnitScope_Global, 0, kReverbLargeSize, 0);
    AudioUnitSetParameter(reverbUnit, kReverbParam_LargeDensity, kAudioUnitScope_Global, 0, kReverbLargeDensity, 0);

    // Ping-pong delay return (see the ivar comment for the topology).
    // Fully wet like the reverb: the dry path never runs through it, the
    // gate only adds echoes on top. Tap times follow delayTapBPM; lane
    // feedback is the per-hop decay squared because each lane repeats every
    // TWO hops.
    float delayHopDecay = kDelayFeedbackPercent / 100.0f;
    float laneFeedbackPercent = delayHopDecay * delayHopDecay * 100.0f;
    NSTimeInterval defaultTap = 30.0 / kDelayDefaultBPM; // 1/8 note = half a beat
    _delaySendGate = [[AVAudioMixerNode alloc] init];
    _delayHalf = [[AVAudioUnitDelay alloc] init];
    _delayHalf.wetDryMix = 100;
    _delayHalf.feedback = 0; // pure T offset, no repeats of its own
    _delayHalf.delayTime = defaultTap;
    _delayLeft = [[AVAudioUnitDelay alloc] init];
    _delayRight = [[AVAudioUnitDelay alloc] init];
    for (AVAudioUnitDelay *lane in @[_delayLeft, _delayRight]) {
        lane.wetDryMix = 100;
        lane.feedback = laneFeedbackPercent;
        lane.delayTime = defaultTap * 2;
    }
    _delayPanLeft = [[AVAudioMixerNode alloc] init];
    _delayPanRight = [[AVAudioMixerNode alloc] init];
    _delaySum = [[AVAudioMixerNode alloc] init];
    _delayLowCut = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
    AVAudioUnitEQFilterParameters *echoCut = _delayLowCut.bands.firstObject;
    echoCut.filterType = AVAudioUnitEQFilterTypeHighPass;
    echoCut.frequency = kDelayEchoLowCutHz;
    echoCut.bypass = NO;
    [engine attachNode:_delaySendGate];
    [engine attachNode:_delayHalf];
    [engine attachNode:_delayLeft];
    [engine attachNode:_delayRight];
    [engine attachNode:_delayPanLeft];
    [engine attachNode:_delayPanRight];
    [engine attachNode:_delaySum];
    [engine attachNode:_delayLowCut];

    AVAudioFormat *mixerFormat = [engine.mainMixerNode outputFormatForBus:0];
    [engine connect:engine.mainMixerNode to:_lowKillEQ format:mixerFormat];
    // One-to-many: the post-low-kill master signal feeds the dry path
    // (masterMix bus 0) and both send taps in parallel.
    [engine connect:_lowKillEQ
        toConnectionPoints:@[
            [[AVAudioConnectionPoint alloc] initWithNode:_masterMix bus:0],
            [[AVAudioConnectionPoint alloc] initWithNode:_reverbSendGate bus:0],
            [[AVAudioConnectionPoint alloc] initWithNode:_delaySendGate bus:0],
        ]
               fromBus:0
                format:mixerFormat];
    [engine connect:_reverbSendGate to:_reverb format:mixerFormat];
    [engine connect:_reverb to:_reverbLowCut format:mixerFormat];
    // connect:to:format: routes to a mixer's next available input bus
    // — the returns land on buses 1 and 2, after the dry path's bus 0.
    [engine connect:_reverbLowCut to:_masterMix format:mixerFormat];
    // Ping-pong lanes (topology in the ivar comment). The gate and
    // delayHalf each fan out one-to-many.
    [engine connect:_delaySendGate
        toConnectionPoints:@[
            [[AVAudioConnectionPoint alloc] initWithNode:_delayHalf bus:0],
            [[AVAudioConnectionPoint alloc] initWithNode:_delayRight bus:0],
        ]
               fromBus:0
                format:mixerFormat];
    [engine connect:_delayHalf
        toConnectionPoints:@[
            [[AVAudioConnectionPoint alloc] initWithNode:_delayPanLeft bus:0],
            [[AVAudioConnectionPoint alloc] initWithNode:_delayLeft bus:0],
        ]
               fromBus:0
                format:mixerFormat];
    [engine connect:_delayLeft to:_delayPanLeft format:mixerFormat]; // bus 1
    [engine connect:_delayRight to:_delayPanRight format:mixerFormat];
    [engine connect:_delayPanLeft to:_delaySum format:mixerFormat];
    [engine connect:_delayPanRight to:_delaySum format:mixerFormat];
    [engine connect:_delaySum to:_delayLowCut format:mixerFormat];
    [engine connect:_delayLowCut to:_masterMix format:mixerFormat];
    [engine connect:_masterMix to:engine.outputNode format:mixerFormat];
    // Mixer state only AFTER the nodes are attached and wired:
    // AVAudioMixerNode's underlying mixer AU doesn't exist until then, and
    // volume/pan written earlier is dropped — the gates would come up at
    // their default (1.0) and the app would launch with the effects audibly
    // stuck on.
    _reverbSendGate.outputVolume = 0;
    _delaySendGate.outputVolume = 0;
    _delayPanLeft.pan = -kDelayPingPongPan;
    _delayPanRight.pan = kDelayPingPongPan;
    // One hop of decay on the right lane: its first tap lands at 2T
    // (hop 2), a full hop after the left lane's T.
    _delayPanRight.outputVolume = delayHopDecay;

    // Apply any intent recorded before the engine existed (a key or menu
    // action racing the async engine init, the controller's first BPM feed).
    [self applyLowKillTargetOnQueue];
    [self applyDelayTapOnQueue];
    os_unfair_lock_lock(&_stateLock);
    BOOL reverbOn = _reverbSendEnabled;
    BOOL delayOn = _delaySendEnabled;
    os_unfair_lock_unlock(&_stateLock);
    if (reverbOn) {
        [self applySendGateOnQueue:_reverbSendGate enabled:YES
                             level:kReverbSendLevel swellRatio:kReverbSwellRatio
                           counter:&_reverbSendRampGeneration];
    }
    if (delayOn) {
        [self applySendGateOnQueue:_delaySendGate enabled:YES
                             level:kDelaySendLevel swellRatio:kDelaySwellRatio
                           counter:&_delaySendRampGeneration];
    }
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

// Runs on _queue. Resolves the ONE cutoff both controls share — the held
// boost (double cutoff) outranks the Q toggle, which outranks parked — and
// sweeps there from wherever the filter is: a re-toggle/release mid-sweep
// bumps the generation, preempting the old sweep, and starts from the
// current frequency (no jump). The bands are un-bypassed while parked
// (transparent, so the flip is inaudible) and re-bypassed only by a
// disengage sweep that reaches the parked cutoff un-preempted.
- (void)applyLowKillTargetOnQueue {
    if (!_engine) {
        return; // Not installed yet; installInEngine: re-applies.
    }
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _lowKillEnabled;
    BOOL boost = _lowKillBoostActive;
    os_unfair_lock_unlock(&_stateLock);
    float target = boost ? kLowKillCutoffHz * kLowKillBoostMultiplier
                 : enabled ? kLowKillCutoffHz
                           : kLowKillParkedHz;
    uint64_t generation = ++_lowKillRampGeneration;
    [self stepLowKillRamp:1 from:_lowKillEQ.bands.firstObject.frequency
                       to:target generation:generation];
}

// The fade-loop pattern applied to the filter cutoff — both cascaded bands
// track the same frequency, stepped along a log-frequency curve
// (multiplicative interpolation, like the volume fades) at the finer
// low-kill cadence.
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

// Runs on _queue. Opens/closes a send gate: a fast fade on the volume-fade
// cadence (an instant volume step clicks; 25ms doesn't), then — while the
// gate stays open — a slow swell up to swellRatio x the base level.
// Closing cuts only the send — the effect keeps rendering, so its tail
// decays naturally. A re-toggle mid-ramp preempts (via the counter) and
// continues from the current gate level.
- (void)applySendGateOnQueue:(AVAudioMixerNode *)gate enabled:(BOOL)enabled level:(float)level swellRatio:(float)swellRatio counter:(uint64_t *)counter {
    if (!_engine) {
        return; // Not installed yet; installInEngine: re-applies.
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
        // Same generation: the release (or a re-press) that would invalidate
        // the swell bumps the counter and the first swell step drops out.
        [weakSelf stepSendGateRamp:gate step:1 of:kSendSwellSteps stepMicroseconds:kSendSwellStepMicroseconds
                              from:level to:level * swellRatio
                        generation:generation counter:counter completion:nil];
    }];
}

// counter points at the owning send's queue-confined ramp generation ivar, so
// the two sends preempt independently. Only dereferenced with self alive (the
// method runs on a strong self), so the pointer can't dangle. The completion
// fires only on an un-preempted run to the target (a preempted ramp's owner
// has moved on — its follow-up must not start).
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
    // Multiplicative (perceptually log) interpolation, like VibeFadeVolume
    // but for an arbitrary step count.
    float f = MAX(start, kFadeFloor);
    float t = MAX(target, kFadeFloor);
    gate.outputVolume = f * powf(t / f, (float)step / (float)steps);
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
        [self applySendGateOnQueue:self->_delaySendGate enabled:enabled
                             level:kDelaySendLevel swellRatio:kDelaySwellRatio
                           counter:&self->_delaySendRampGeneration];
    });
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
        return; // Called on every fader tick — only real changes touch the queue.
    }
    _delayTapBPM = bpm;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self applyDelayTapOnQueue];
    });
}

// Runs on _queue. 1/8 note = half a beat. The delays sit post-varispeed, so
// this is wall-clock time — matching the effective (pitch-scaled) tempo the
// controller provides. The lanes run at 2T (see the topology comment);
// AVAudioUnitDelay caps delayTime at 2s, so 2T pins there below 30 BPM
// effective — beyond any real tempo.
- (void)applyDelayTapOnQueue {
    if (!_engine) {
        return; // Not installed yet; installInEngine: re-applies.
    }
    os_unfair_lock_lock(&_stateLock);
    float bpm = _delayTapBPM;
    os_unfair_lock_unlock(&_stateLock);
    float effectiveBPM = bpm > 0 ? bpm : kDelayDefaultBPM;
    NSTimeInterval tap = 30.0 / effectiveBPM;
    _delayHalf.delayTime = tap;
    _delayLeft.delayTime = tap * 2;
    _delayRight.delayTime = tap * 2;
}

@end

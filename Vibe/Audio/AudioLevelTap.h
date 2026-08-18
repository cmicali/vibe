//
//  AudioLevelTap.h
//  Vibe
//
//  A tap on one AVAudioNode's output that publishes kLevelBandCount band
//  levels for the equalizer indicator to draw. Plain ObjC over Accelerate, so
//  no C++ reaches a header.
//
//  WHERE IT TAPS IS THE WHOLE DESIGN. AudioPlayer installs it on
//  mainMixerNode bus 0, which — with the FX segment absent, as it is on iOS —
//  is exactly the signal reaching the speaker: post-fade, post-varispeed, and
//  the crossfade sum comes free because both chains already meet there. With FX
//  enabled the reverb and delay returns re-enter downstream of that mixer, so
//  the same tap point would miss every wet tail; that is why levels are an iOS
//  feature and not a macOS one.
//
//  It publishes instantaneous levels at the hop rate and smooths nothing. The
//  envelope belongs to the view, per displayed frame, so motion stays tied to
//  the display rather than to the tap — and so a tap that stops firing decays
//  gracefully instead of freezing, which matters because the engine's deferred
//  idle stop takes the tap with it a few seconds after a pause.
//
//  Lives in the shared Vibe/Audio/, so it compiles into both targets, but only
//  iOS ever asks for one — the same shape as FolderArtResolver, which likewise
//  builds for both and is simply never handed to anything on iOS.
//

#import <AVFoundation/AVFoundation.h>

#import "AudioLevelMath.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioLevelTap : NSObject

// Installs the tap immediately, binding the band edges to the sample rate the
// node actually delivers. Call on the owner's queue — AudioPlayer's, which is
// the only writer of the engine graph.
- (instancetype)initWithNode:(AVAudioNode *)node NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Removes the tap from a LIVE node. Call on the same queue as init.
- (void)remove;

// Forgets the node without messaging it, for a graph that died under us — an
// iOS media-services reset, where touching the defunct engine is the trap
// dropEngineBoundStateOnQueue exists to avoid.
- (void)abandon;

// Lock-free and callable at display rate from the main thread: fills `out`
// with `count` levels in 0..1. NO means no levels are available and `out` is
// untouched, which the caller should read as "keep decaying", not as silence.
- (BOOL)copyLevels:(float *)out count:(NSUInteger)count;

@end

NS_ASSUME_NONNULL_END

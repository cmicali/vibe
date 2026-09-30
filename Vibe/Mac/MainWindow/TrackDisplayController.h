//
//  TrackDisplayController.h
//  Vibe
//
//  Draws the header — labels, times, the codec and BPM corner, the drop hint —
//  and the waveform's rendering states. Pure rendering: MainPlayerController
//  resolves the state, and this reads no player or playlist state.
//

#import <Cocoa/Cocoa.h>
#import "TrackDisplayRules.h"

@class AudioTrack;
@class CodableAudioWaveform;
@class MainPlayerContentView;

NS_ASSUME_NONNULL_BEGIN

// The deck state on the codec line, mirroring the AudioFX flags and the
// player's bit-perfect report.
typedef struct {
    BOOL lowKill;       // Q — low-kill high-pass
    BOOL lowKillBoost;  // W — doubles Q's cutoff (renders as the filled dial)
    BOOL reverb;        // E
    BOOL delay;         // R — 1/8-note echo
    BOOL shortDelay;    // T — 1/16-note echo
    // 0 = mode off (no glyph), 1 = mode on but not delivering (open lock; the
    // reason is the tooltip, renderBitPerfectToolTip:), 2 = delivering
    // (closed lock).
    NSInteger bitPerfect;
} VibeFXDisplayState;

// Main thread only.
@interface TrackDisplayController : NSObject

// The content view keeps ownership of the adopted views.
- (instancetype)initWithContentView:(MainPlayerContentView *)contentView;

// track: the displayed track for Track and Loading, the errored track for
// Error, nil otherwise. duration is file time; the labels divide it by rate.
// errorStatus is the track's play error: in Error the artist line, where nil
// reads as the generic playback error; in Track, a parked track's, it stands
// in for the file info line. In Empty, errorStatus over errorTitle says why
// an open found nothing to play; nil leaves both lines blank.
- (void)renderState:(TrackDisplayState)state
              track:(nullable AudioTrack *)track
           duration:(NSTimeInterval)duration
               rate:(double)rate
        errorStatus:(nullable NSString *)errorStatus
         errorTitle:(nullable NSString *)errorTitle;

// The position tick. duration is the caller's cache: the live one reads 0
// while Loading.
- (void)renderPosition:(NSTimeInterval)position
              duration:(NSTimeInterval)duration
                  rate:(double)rate
                 state:(TrackDisplayState)state;

// The right time label alone, cheap enough for fader ticks. Track only.
- (void)renderTotalDuration:(NSTimeInterval)duration rate:(double)rate state:(TrackDisplayState)state;

// The sentence explaining an open lock, or nil. The whole line is the target.
- (void)renderBitPerfectToolTip:(nullable NSString *)toolTip;

// The BPM and key line. The caller owns precedence, rate scaling and notation;
// a BPM <= 0 or an empty key clears its half. colorKey is the VibeMusicalKey
// whose Camelot color the key draws in, bold, or -1 for none.
- (void)renderBPM:(float)displayBPM keyText:(NSString *)keyText colorKey:(NSInteger)colorKey;

// Symbols for the active effects, inline at the head of the codec line. FX
// outlive tracks, so the line composes from the last text and the last state.
- (void)renderFXState:(VibeFXDisplayState)state;

// A no-op unless the title label's width changed.
- (void)refitTitleIfWidthChanged;

// The Fonts effect's hook, where the width check would see nothing move.
- (void)refitTitle;

// The TrackDisplay effect's hook: the next updateUI repaints in the new colors.
- (void)resetRenderGuards;

// The end-of-track park: progress 0, 0:00, the right label at full length.
// duration is the finished track's own; the player's is mid-teardown.
- (void)resetPlayheadToStartWithDuration:(NSTimeInterval)duration rate:(double)rate;

// Forwarded to the view, which stays a plain surface.
- (void)prepareForWaveformLoad;
- (void)showWaveform:(CodableAudioWaveform *)waveform;
// Slow-open playback and the debug channel's set_loading drive this directly.
- (void)showWaveformLoadingIndicator;
- (void)hideWaveformLoadingIndicator;
// Determinate download fill; negative reverts to the indeterminate shimmer.
- (void)setWaveformLoadingProgress:(float)fraction;
// Convert to FLAC's sweep; 0 resets it. The getter serves the debug dump.
- (void)setConvertSweepFraction:(double)fraction;
- (double)convertSweepFraction;

// For the debug channel's state dump and consistency check.
@property (weak, readonly) NSTextField *artistTextField;
@property (weak, readonly) NSTextField *titleTextField;
@property (weak, readonly) NSTextField *totalTimeTextField;
@property (weak, readonly) NSTextField *currentTimeTextField;
@property (weak, readonly) NSTextField *fileMetadataTextField;

@end

NS_ASSUME_NONNULL_END

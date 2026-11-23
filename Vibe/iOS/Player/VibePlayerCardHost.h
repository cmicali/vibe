//
//  VibePlayerCardHost.h
//  Vibe (iOS)
//
//  The app as the now-playing card sees it: the card's words, how it formats
//  times and info lines, and the settings it draws from. The card reads no
//  setting, string or formatter of the app's. It asks the host, live, so a
//  setting written anywhere shows at the next render. The app installs one
//  host at launch, before any card is made.
//
//  Main thread only.
//

#import <UIKit/UIKit.h>

#import "AudioWaveformCache.h"
#import "VibePlayerCardPlayback.h"

@class WaveformScrubberView;

NS_ASSUME_NONNULL_BEGIN

// Every word the card shows or speaks.
typedef NS_ENUM(NSInteger, VibePlayerCardLabel) {
    // A time the card does not know yet.
    VibePlayerCardLabelTimeUnknown,
    VibePlayerCardLabelBuffering,
    // VoiceOver labels.
    VibePlayerCardLabelMinimize,
    VibePlayerCardLabelOutputRoute,
    VibePlayerCardLabelWaveform,
    // The right time, a button that flips its mode.
    VibePlayerCardLabelTime,
    VibePlayerCardLabelShuffle,
    VibePlayerCardLabelPrevious,
    VibePlayerCardLabelNext,
    VibePlayerCardLabelPlay,
    VibePlayerCardLabelPause,
    // The FX pad: its pill, its two axis captions, and its VoiceOver label
    // and hint.
    VibePlayerCardLabelFXPill,
    VibePlayerCardLabelFXAxisLowCut,
    VibePlayerCardLabelFXAxisReverbDelay,
    VibePlayerCardLabelFXPad,
    VibePlayerCardLabelFXPadHint,
};

@protocol VibePlayerCardHost <NSObject>

- (NSString *)playerCardLabel:(VibePlayerCardLabel)label;
// The repeat button's VoiceOver label, which names the mode it is in.
- (NSString *)playerCardRepeatTitle:(VibeRepeatMode)mode;

// A track time, such as 3:05.
- (NSString *)playerCardDuration:(NSTimeInterval)duration;
// The codec line and the tempo line. nil hides the line.
- (nullable NSString *)playerCardFileInfoForItem:(id<VibePlayerCardItem>)item;
- (nullable NSString *)playerCardTempoForItem:(id<VibePlayerCardItem>)item;
// The non-empty fields joined into one info line.
- (NSString *)playerCardInfoLineFromFields:(NSArray<NSString *> *)fields;

// The right time shows what is left, minus-prefixed, rather than the
// duration. A tap on it writes the flipped value.
@property (nonatomic) BOOL playerCardShowsRemainingTime;
@property (nonatomic, readonly) BOOL playerCardShowsFXPad;
@property (nonatomic, readonly) BOOL playerCardShowsShuffleRepeat;
// The art a page draws when its track has none.
@property (nonatomic, readonly) UIImage *playerCardPlaceholderArt;

// Pushes every waveform setting into a page's scrubber, which reads no store:
// the style, Centered, the playhead line and the theme provider.
- (void)playerCardConfigureWaveformView:(WaveformScrubberView *)view;
// Once, when the card makes its waveform cache, before the first lookup.
// The host sets the cache's analysis provider, which is asked once per
// request, and may queue an invalidation.
- (void)playerCardConfigureWaveformCache:(AudioWaveformCache *)cache;

@end

// Once, at launch, before any card is made.
void VibePlayerCardInstallHost(id<VibePlayerCardHost> host);
// nil before the install.
id<VibePlayerCardHost> _Nullable VibePlayerCardInstalledHost(void);
// The host's word, or empty before the install.
NSString *VibePlayerCardLabelText(VibePlayerCardLabel label);

NS_ASSUME_NONNULL_END

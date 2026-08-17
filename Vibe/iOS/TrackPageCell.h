//
//  TrackPageCell.h
//  Vibe (iOS)
//
//  One full-screen page of the track pager: the blurred art background, the
//  Apple Music-style art card above the waveform (portrait), and the page's
//  own waveform strip — every page carries a waveform view, so a neighbor
//  pulled into view shows its own track's waveform, already loading. In
//  landscape the cell rearranges into the mac main window: a small square
//  art card top-left, artist over title beside it, the codec line top-right,
//  the waveform full-width. The transport row rides the page too — under the
//  time labels in portrait, on their centerline in landscape.
//
//  The waveform, the time row and the transport are one chain off the safe
//  bottom, and the header labels have reserved heights, so the waveform sits
//  at the same y on every page whatever the title and artist are.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class WaveformScrubberView;

// The transport row's container, a class of its own so the card's
// tap-anywhere-to-pause can decline every touch that lands in the row.
//
// TRAP: a UIControl check is not enough. Hit-testing does NOT hand back a
// disabled button — the touch falls through to the view behind it — so a tap
// on next at the end of the playlist paused playback instead of doing nothing.
@interface VibeTransportRowView : UIView
@end

// The right-hand time label, a class of its own for the same reason: it takes
// its own tap — total time vs remaining — so the card's tap-anywhere-to-pause
// has to decline it, and class membership is how that check is written.
@interface VibeTimeLabel : UILabel
@end

@interface TrackPageCell : UICollectionViewCell

@property (class, readonly) NSString *reuseIdentifier;

// The page's waveform and time labels. The owning controller wires the
// waveform delegate, routes cache deliveries to the loading page's view, and
// drives the current page's labels live; neighbors keep their configured
// resting values.
@property (nonatomic, readonly) WaveformScrubberView *waveformView;
@property (nonatomic, readonly) UILabel *elapsedLabel;
// Shows the total duration, or the minus-prefixed remaining time once tapped.
// Its recognizer is exposed rather than a target: the mode is one setting for
// the whole app, so the controller owns the toggle and every page follows.
@property (nonatomic, readonly) VibeTimeLabel *remainingLabel;
@property (nonatomic, readonly) UITapGestureRecognizer *remainingLabelTap;

// The transport row — previous, play/pause, next — and its buttons. The
// controller wires the three actions, swaps the play/pause symbol, and fades
// the row as a unit (the empty state shows none of it).
@property (nonatomic, readonly) VibeTransportRowView *transportView;
@property (nonatomic, readonly) UIButton *previousButton;
@property (nonatomic, readonly) UIButton *playPauseButton;
@property (nonatomic, readonly) UIButton *nextButton;

// Swaps the glyph between play and pause (symbol + accessibility label).
- (void)setGlyphPlaying:(BOOL)playing;

// Dims and disables next at the playlist's end. Per PAGE, not per playing
// track: the button is the page's own, so a swipe onto the last one finds it
// already dimmed.
- (void)setNextEnabled:(BOOL)enabled;

- (void)configureWithTitle:(NSString *)title
                titleColor:(UIColor *)titleColor
                    artist:(NSString *)artist
               artistColor:(UIColor *)artistColor
                  fileInfo:(NSString *)fileInfo
                       art:(nullable UIImage *)art;

@end

NS_ASSUME_NONNULL_END

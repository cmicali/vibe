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
//  Portrait ends in an action bar: a capsule off the safe bottom carrying the
//  output-route control, which is the only thing in it so far. Landscape has
//  no height for one, so the bar is hidden there and the route control takes
//  the top-trailing corner instead.
//
//  The waveform, the time row, the transport and the action bar are one chain
//  off the safe bottom, and the header labels have reserved heights, so the
//  waveform sits at the same y on every page whatever the title and artist
//  are.
//

#import <UIKit/UIKit.h>

@class OutputRouteView;

NS_ASSUME_NONNULL_BEGIN

@class WaveformScrubberView;

// The transport row's container, a class of its own so the card's
// tap-anywhere-to-pause can decline every touch that lands in the row.
//
// TRAP: a UIControl check is not enough. Hit-testing does NOT hand back a
// disabled button — the touch falls through to the view behind it — so a tap
// on next at the end of the playlist paused playback instead of doing nothing.
@interface TrackPageTransportView : UIView
@end

// Portrait's bottom action bar — a capsule behind the controls that sit in it.
// A class of its own for the same reason the transport row is one: the card's
// tap-anywhere-to-pause must decline every touch that lands in the bar, and the
// backdrop between two controls is not a UIControl to test for.
@interface TrackPageActionBarView : UIView
@end

// The right-hand time readout is a control because tapping it changes the
// total-vs-remaining mode. Its intrinsic height is a 44pt hit target while its
// internal label stays visually aligned with the elapsed time.
@interface TrackPageTimeControl : UIControl
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSTextAlignment textAlignment;
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
// The mode is one setting for the whole app, so the controller owns the target
// and every page follows.
@property (nonatomic, readonly) TrackPageTimeControl *remainingTimeControl;

// The transport row — previous, play/pause, next — and its buttons. The
// controller wires the three actions, swaps the play/pause symbol, and fades
// the row as a unit (the empty state shows none of it).
@property (nonatomic, readonly) TrackPageTransportView *transportView;
// The output-route indicator, centered in the action bar in portrait and in
// the top-trailing corner in landscape. It rides the page for the same reason
// the transport does; the controller wires its delegate and pushes the route
// every page draws.
@property (nonatomic, readonly) OutputRouteView *routeView;
// The capsule behind it, portrait only. Exposed so the controller can fade it
// with the rest of the chrome — the empty state shows none of it.
@property (nonatomic, readonly) TrackPageActionBarView *actionBar;
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
                  fileInfo:(nullable NSString *)fileInfo
                       art:(nullable UIImage *)art;

@end

NS_ASSUME_NONNULL_END

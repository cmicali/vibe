//
//  TrackPageCell.h
//  Vibe (iOS)
//
//  One full-screen page. Every page carries its own waveform, so a neighbor
//  pulled into view shows its own track's. Portrait ends in two capsules, the
//  FX pad and the route control (the route capsule alone with effects off).
//  Landscape rearranges into the mac main window and hides both.
//

#import <UIKit/UIKit.h>

@class FXPadView;
@class OutputRouteView;

NS_ASSUME_NONNULL_BEGIN

@class WaveformScrubberView;

// A class of its own so the card's tap-to-pause declines the whole row.
// TRAP: a UIControl check is not enough. Hit-testing does NOT hand back a
// disabled button, so a tap on a dimmed next falls through and pauses.
@interface TrackPageTransportView : UIView
@end

// Portrait's bottom capsule; a class of its own for the same reason: the
// backdrop between controls is not a UIControl.
@interface TrackPageActionBarView : UIView
@end

// A control because a tap flips the time mode; a 44pt target whose label
// stays aligned with the elapsed time.
@interface TrackPageTimeControl : UIControl
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSTextAlignment textAlignment;
@end

@interface TrackPageCell : UICollectionViewCell

@property (class, readonly) NSString *reuseIdentifier;

@property (nonatomic, readonly) WaveformScrubberView *waveformView;
@property (nonatomic, readonly) UILabel *elapsedLabel;
// One mode for the whole app, so the controller owns the target.
@property (nonatomic, readonly) TrackPageTimeControl *remainingTimeControl;

@property (nonatomic, readonly) TrackPageTransportView *transportView;
@property (nonatomic, readonly) OutputRouteView *routeView;
// Exposed so the controller can fade it with the chrome.
@property (nonatomic, readonly) TrackPageActionBarView *actionBar;
// The FX pad, the left capsule of portrait's action bar. It rides the page
// like the route control; the controller wires its delegate and, because
// it owns the touch for the length of a hold, holds the pager still for it.
// Hidden with the setting (setFXPadShown:) and in landscape.
@property (nonatomic, readonly) FXPadView *fxPadView;
// Settings > Playback > Enable audio effects: shown, the bar is the two
// capsules; hidden, the route capsule takes the whole width, the layout
// before the pad existed. The controller sets it from the setting on every
// configure, so a recycled cell and a settings change both land.
- (void)setFXPadShown:(BOOL)shown;
@property (nonatomic, readonly) UIButton *previousButton;
@property (nonatomic, readonly) UIButton *playPauseButton;
@property (nonatomic, readonly) UIButton *nextButton;

- (void)setGlyphPlaying:(BOOL)playing;

// Per PAGE, not per playing track, so the last page arrives dimmed.
- (void)setNextEnabled:(BOOL)enabled;

- (void)configureWithTitle:(NSString *)title
                titleColor:(UIColor *)titleColor
                    artist:(NSString *)artist
               artistColor:(UIColor *)artistColor
                  fileInfo:(nullable NSString *)fileInfo
                       art:(nullable UIImage *)art;

@end

NS_ASSUME_NONNULL_END

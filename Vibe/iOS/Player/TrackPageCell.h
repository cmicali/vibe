//
//  TrackPageCell.h
//  Vibe (iOS)
//
//  One full-screen page. Every page carries its own waveform, so a neighbor
//  pulled into view shows its own track's. Portrait ends in the FX pad's
//  circle and the route capsule (the route capsule alone with effects off).
//  Landscape rearranges into the mac main window, with the two in its bottom
//  corners.
//

#import <UIKit/UIKit.h>

#import "OutputRouteRules.h"
#import "RepeatMode.h"

@class FXPadView;
@class OutputRouteView;

NS_ASSUME_NONNULL_BEGIN

@class WaveformScrubberView;

// The route capsule, which rounds its own ends.
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

@property (nonatomic, readonly) UIView *transportView;
@property (nonatomic, readonly) OutputRouteView *routeView;
// Exposed so the controller can fade it with the chrome.
@property (nonatomic, readonly) TrackPageActionBarView *actionBar;
// The FX pad: the circle at the leading end of portrait's action bar, and in
// landscape's bottom-leading corner. It rides the page like the route control;
// the controller wires its delegate and, because it owns the touch for the
// length of a hold, holds the pager still for it. Hidden with the setting
// (setFXPadShown:).
@property (nonatomic, readonly) FXPadView *fxPadView;
// Settings > Playback > Enable audio effects: shown, portrait's bar is the
// pad's circle and the route capsule over the rest; hidden, the route capsule
// takes the whole width. The controller sets it from the setting on every
// configure, so a recycled cell and a settings change both land.
- (void)setFXPadShown:(BOOL)shown;
@property (nonatomic, readonly) UIButton *previousButton;
@property (nonatomic, readonly) UIButton *playPauseButton;
@property (nonatomic, readonly) UIButton *nextButton;
// The row's ends: shuffle leading, repeat trailing. The three between keep
// their spacing; the gaps out to these give first on a narrow screen.
@property (nonatomic, readonly) UIButton *shuffleButton;
@property (nonatomic, readonly) UIButton *repeatButton;

- (void)setGlyphPlaying:(BOOL)playing;

// The route goes through the cell, not the route view: landscape's right time
// label aligns to what the pill drew.
- (void)setOutputRouteKind:(VibeOutputRouteKind)kind deviceName:(nullable NSString *)name;

// The controller's answer for this page: from its index, so the last page
// arrives dimmed, except the current page, which asks the playlist.
- (void)setNextEnabled:(BOOL)enabled;

// Off draws dimmed, on at full strength; Repeat One shows its own glyph.
- (void)setShuffleEnabled:(BOOL)shuffleEnabled repeatMode:(VibeRepeatMode)repeatMode;

// The appearance setting, set on every configure: hidden, the two flanks and
// their gaps collapse to nothing, so the three keep their full spacing.
- (void)setShuffleRepeatShown:(BOOL)shown;

- (void)configureWithTitle:(NSString *)title
                titleColor:(UIColor *)titleColor
                    artist:(NSString *)artist
               artistColor:(UIColor *)artistColor
                  fileInfo:(nullable NSString *)fileInfo
                 tempoInfo:(nullable NSString *)tempoInfo
                       art:(nullable UIImage *)art;

@end

NS_ASSUME_NONNULL_END

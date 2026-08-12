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
//  the waveform full-width. The play glyph rides the page too, between the
//  time labels; only the search bar and folder button stay overlaid in
//  PlayerViewController.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class WaveformScrubberView;

@interface TrackPageCell : UICollectionViewCell

@property (class, readonly) NSString *reuseIdentifier;

// The page's waveform and time labels. The owning controller wires the
// waveform delegate, routes cache deliveries to the loading page's view, and
// drives the current page's labels live; neighbors keep their configured
// resting values.
@property (nonatomic, readonly) WaveformScrubberView *waveformView;
@property (nonatomic, readonly) UILabel *elapsedLabel;
@property (nonatomic, readonly) UILabel *remainingLabel;

// The paused-state play glyph between the time labels. The controller wires
// the action, swaps the symbol, and drives visibility (hidden while playing).
@property (nonatomic, readonly) UIButton *playPauseButton;

// Swaps the glyph between play and pause (symbol + accessibility label).
- (void)setGlyphPlaying:(BOOL)playing;

- (void)configureWithTitle:(NSString *)title
                titleColor:(UIColor *)titleColor
                    artist:(NSString *)artist
               artistColor:(UIColor *)artistColor
                  fileInfo:(NSString *)fileInfo
                       art:(nullable UIImage *)art;

@end

NS_ASSUME_NONNULL_END

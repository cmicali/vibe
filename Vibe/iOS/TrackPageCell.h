//
//  TrackPageCell.h
//  Vibe (iOS)
//
//  One full-screen page of the track pager: the blurred art background, the
//  header (artist over title top-left, the codec corner top-right), and the
//  page's own waveform strip — every page carries a waveform view, so a
//  neighbor pulled into view shows its own track's waveform, already
//  loading. The transport, search bar, and folder button stay overlaid in
//  PlayerViewController and never scroll.
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

- (void)configureWithTitle:(NSString *)title
                titleColor:(UIColor *)titleColor
                    artist:(NSString *)artist
               artistColor:(UIColor *)artistColor
                  fileInfo:(NSString *)fileInfo
                       art:(nullable UIImage *)art;

@end

NS_ASSUME_NONNULL_END

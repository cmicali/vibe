//
//  TrackPageCell.h
//  Vibe (iOS)
//
//  One full-screen page of the track pager: the blurred art background and
//  the header (artist over title top-left, the codec corner top-right). The
//  live chrome — waveform, transport, time, bottom bar — stays overlaid in
//  PlayerViewController and never scrolls with the pages.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TrackPageCell : UICollectionViewCell

@property (class, readonly) NSString *reuseIdentifier;

- (void)configureWithTitle:(NSString *)title
                titleColor:(UIColor *)titleColor
                    artist:(NSString *)artist
               artistColor:(UIColor *)artistColor
                  fileInfo:(NSString *)fileInfo
                       art:(nullable UIImage *)art;

@end

NS_ASSUME_NONNULL_END

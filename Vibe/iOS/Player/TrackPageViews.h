//
//  TrackPageViews.h
//  Vibe (iOS)
//
//  The small views a TrackPageCell is built from.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

static const CGFloat kArtCornerRadius = 12;

// The time labels' font, color and placeholder text.
void VibeConfigureTimeLabel(UILabel *label);

// The route capsule, which rounds its own ends.
@interface TrackPageActionBarView : UIView
@end

// A control because a tap flips the time mode; a 44pt target whose label
// stays aligned with the elapsed time.
@interface TrackPageTimeControl : UIControl
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSTextAlignment textAlignment;
@end

// The art's card, which restates its own shadow path.
@interface TrackPageArtCardView : UIView
@end

NS_ASSUME_NONNULL_END

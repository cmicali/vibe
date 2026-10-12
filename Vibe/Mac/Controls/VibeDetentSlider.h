//
//  VibeDetentSlider.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Ticks above and below the track at detentValue, where its action snaps.
// NSSlider's own tick marks are evenly spaced and single-sided.
@interface VibeDetentSlider : NSSlider
@property (nonatomic) double detentValue;
@end

NS_ASSUME_NONNULL_END

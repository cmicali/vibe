//
//  MiniPlayerView.h
//  Vibe (iOS)
//
//  The strip in the tab bar's bottomAccessory. Tapping it anywhere but a
//  control, or swiping up, expands the card. It draws only what it is told,
//  and reads no model, setting or string.
//

#import <UIKit/UIKit.h>

@class MiniPlayerView;
@class VibeTrackRow;

NS_ASSUME_NONNULL_BEGIN

@protocol MiniPlayerViewDelegate <NSObject>
- (void)miniPlayerViewDidRequestExpand:(MiniPlayerView *)view;
- (void)miniPlayerViewDidTapPlayPause:(MiniPlayerView *)view;
- (void)miniPlayerViewDidTapNext:(MiniPlayerView *)view;
@end

@interface MiniPlayerView : UIView

@property (nonatomic, weak) id<MiniPlayerViewDelegate> delegate;

// VoiceOver's names for the strip's controls. The expand label names what a
// tap on the strip shows.
@property (nonatomic, copy, nullable) NSString *expandAccessibilityLabel;
@property (nonatomic, copy, nullable) NSString *playAccessibilityLabel;
@property (nonatomic, copy, nullable) NSString *pauseAccessibilityLabel;
@property (nonatomic, copy, nullable) NSString *nextAccessibilityLabel;

// The title, subtitle and thumbnail; the rest of the row is not drawn. The
// thumbnail is the small row art, never a full-size decode.
- (void)renderRow:(nullable VibeTrackRow *)row;
- (void)setPlaying:(BOOL)playing;

@end

NS_ASSUME_NONNULL_END

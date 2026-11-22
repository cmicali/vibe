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

// VoiceOver's names for the strip's controls. Expand names what a tap on the
// strip shows. The play button takes play or pause, whichever a tap will do.
- (void)setAccessibilityLabelsForExpand:(NSString *)expand
                                   play:(NSString *)play
                                  pause:(NSString *)pause
                                   next:(NSString *)next;

// The title, subtitle and thumbnail; the rest of the row is not drawn. The
// thumbnail is the small row art, never a full-size decode.
- (void)renderRow:(nullable VibeTrackRow *)row;
- (void)setPlaying:(BOOL)playing;

@end

NS_ASSUME_NONNULL_END

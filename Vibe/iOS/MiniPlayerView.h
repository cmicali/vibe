//
//  MiniPlayerView.h
//  Vibe (iOS)
//
//  The strip in the tab bar's bottomAccessory. Tapping it anywhere but a
//  control, or swiping up, expands the card. It draws only what it is told.
//

#import <UIKit/UIKit.h>

@class AudioTrack;
@class MiniPlayerView;

NS_ASSUME_NONNULL_BEGIN

@protocol MiniPlayerViewDelegate <NSObject>
- (void)miniPlayerViewDidRequestExpand:(MiniPlayerView *)view;
- (void)miniPlayerViewDidTapPlayPause:(MiniPlayerView *)view;
- (void)miniPlayerViewDidTapNext:(MiniPlayerView *)view;
@end

@interface MiniPlayerView : UIView

@property (nonatomic, weak) id<MiniPlayerViewDelegate> delegate;

// Art is the 128px thumbnail, never the card's full-size decode.
- (void)renderTrack:(nullable AudioTrack *)track;
- (void)setPlaying:(BOOL)playing;

@end

NS_ASSUME_NONNULL_END

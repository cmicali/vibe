//
//  MiniPlayerView.h
//  Vibe (iOS)
//
//  The minimized player: the strip that lives in the tab bar controller's
//  bottomAccessory, above the tab bar. Artwork, title over artist, play/pause
//  and next. Tapping it anywhere but a control — or swiping it up — expands
//  the full-screen card.
//
//  It draws only what it is told; the events come from PlaybackController
//  through RootViewController, which owns both this and the card.
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

// The strip's whole content. Art is the 128px thumbnail — the size this draws
// at — never the full-size decode the card's pages hold.
- (void)renderTrack:(nullable AudioTrack *)track;
- (void)setPlaying:(BOOL)playing;

@end

NS_ASSUME_NONNULL_END

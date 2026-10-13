// Playback settings apply through PlaybackController. BPM detection is read
// on the next waveform request. The FX switch also notifies the card.

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackSettingsViewController : UITableViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

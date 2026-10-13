//
//  RecentsViewController.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

#import "PlaybackController.h"

NS_ASSUME_NONNULL_BEGIN

// Every file and folder played or added, newest first (RecentsStore). A file
// plays alone, as a search hit does; a folder opens in the browser. Its own
// screen rather than a browser mode: it lists no directory, and every one of
// the browser's directory branches would need a third arm.
@interface RecentsViewController : UITableViewController <PlaybackObserver>
- (instancetype)initWithPlayback:(PlaybackController *)playback appending:(BOOL)appending;
@end

NS_ASSUME_NONNULL_END

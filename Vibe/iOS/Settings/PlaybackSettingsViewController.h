//
//  PlaybackSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Playback: what the player does between tracks — the mac pane's
//  Track transitions group, On track end and Crossfade. The rest of that pane
//  (pitch range, skip steps, audio effects, analysis) is macOS-only
//  (Vibe/Common/CLAUDE.md), so this is the whole of what there is to set.
//
//  Two value rows, each pushing its own picker. Unlike the Appearance screen,
//  a write here notifies no screen: nothing draws from these, the player
//  plays from them, so each write ends on the model's
//  applyTrackTransitionSettings, which pushes the crossfade and re-parks or
//  drops the prefetched successor.
//

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

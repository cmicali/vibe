//
//  PlaybackSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Playback: what the player does between tracks — the mac pane's
//  Track transitions group, On track end and Crossfade — plus Resampling
//  (iOS's own), the audio effects switch and BPM detection. The rest of that
//  pane (pitch range, skip steps, key analysis) is macOS-only
//  (Vibe/Common/CLAUDE.md), so this is the whole of what there is to set.
//
//  Value rows push their own picker; the switches write in place. A write
//  here ends on the model — applyTrackTransitionSettings, which pushes the
//  crossfade and re-parks or drops the prefetched successor;
//  applyResamplingSetting; applyFXSetting — because the player plays from
//  these. The effects switch also notifies the card, since the FX pad it
//  shows or hides is drawn from the setting; BPM detection notifies nothing,
//  the loader asks on its next decode.
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

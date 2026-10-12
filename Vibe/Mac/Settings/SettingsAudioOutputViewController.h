//
//  SettingsAudioOutputViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

@interface SettingsAudioOutputViewController : SettingsPaneViewController

// Outside callers reach both through SettingsWindowController.audioPane, nil
// unless the pane is on screen.
- (void)refreshOutputDevice;

// The player controller calls this when the bit-perfect report changes; the
// pane observes no playback of its own.
- (void)refreshBitPerfectRows;

@end

//
//  SettingsGeneralViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

@interface SettingsGeneralViewController : SettingsPaneViewController

// General, Audio Output and Appearance share this controller; each instance
// builds only its own page, named by its pane identifier.
- (instancetype)initWithPlayerController:(MainPlayerController *)playerController page:(NSString *)page;

// Outside callers reach both through SettingsWindowController.audioPane, nil
// unless the pane is on screen.
- (void)refreshOutputDevice;

// The player controller calls this when the bit-perfect report changes; the
// pane observes no playback of its own.
- (void)refreshBitPerfectRows;

@end

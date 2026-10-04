//
//  SettingsGeneralViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

typedef NS_ENUM(NSInteger, SettingsGeneralPage) {
    SettingsGeneralPageGeneral,
    SettingsGeneralPageAudio,
    SettingsGeneralPageAppearance,
};

@interface SettingsGeneralViewController : SettingsPaneViewController

// General, Audio Output and Appearance share this controller; each instance
// builds only its own page.
- (instancetype)initWithPlayerController:(MainPlayerController *)playerController page:(SettingsGeneralPage)page;

// Outside callers reach both through SettingsWindowController.audioPane, nil
// unless the pane is on screen.
- (void)refreshOutputDevice;

// The player controller calls this when the bit-perfect report changes; the
// pane observes no playback of its own.
- (void)refreshBitPerfectRows;

@end

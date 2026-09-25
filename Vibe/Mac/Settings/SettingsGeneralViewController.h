//
//  SettingsGeneralViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

@interface SettingsGeneralViewController : SettingsPaneViewController

// Audio and General share this controller; each instance builds only its own page.
- (instancetype)initWithPlayerController:(MainPlayerController *)playerController audioPane:(BOOL)audioPane;

// Refresh after the player's asynchronous device selection settles. Outside
// callers reach it through SettingsWindowController.audioPane, which answers
// nil unless the pane is on screen; the pane's own appearance refreshes it.
- (void)refreshOutputDevice;

// The bit-perfect switch and its caption, which is the player's live report:
// the player controller calls this when that report changes, since the pane
// has no observation of playback of its own, through audioPane as above.
- (void)refreshBitPerfectRows;

@end

//
//  SettingsGeneralViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

@interface SettingsGeneralViewController : SettingsPaneViewController

// The bit-perfect switch and its caption, which is the player's live report:
// the player controller calls this when that report changes, since the pane
// has no observation of playback of its own. A no-op before the view loads.
- (void)refreshBitPerfectRows;

@end

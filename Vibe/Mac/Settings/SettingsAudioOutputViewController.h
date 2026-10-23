//
//  SettingsAudioOutputViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

@class MainPlayerController;

@interface SettingsAudioOutputViewController : SettingsPaneViewController

// The device list, the mode switches and the bit-perfect report are the
// player's.
@property (weak, readonly) MainPlayerController *playerController;

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController
                             effectsSink:(void (^)(NSUInteger effects))sink;

// Outside callers reach both through SettingsWindowController.audioPane, nil
// unless the pane is on screen.
- (void)refreshOutputDevice;

// The player controller calls this when the bit-perfect report changes; the
// pane observes no playback of its own.
- (void)refreshBitPerfectRows;

@end

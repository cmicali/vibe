//
//  SettingsAdvancedViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

@class MainPlayerController;

@interface SettingsAdvancedViewController : SettingsPaneViewController

// The cache readouts, the audio path and Restore Defaults are the player's.
@property (weak, readonly) MainPlayerController *playerController;

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController
                             effectsSink:(void (^)(NSUInteger effects))sink;

@end

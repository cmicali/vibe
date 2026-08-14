//
//  AppDelegate.h
//  Vibe
//
//  Created by Christopher Micali on 12/14/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#define SHOW_EXTENDED_BUILD_INFO 0

@class MainPlayerController;

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) MainPlayerController *mainPlayerController;

- (IBAction)openDocument:(id)sender;
- (IBAction)showAboutWindow:(id)sender;
- (IBAction)showSettingsWindow:(id)sender;

// The target of the Open Recent menu items OpenRecentMenuController creates.
- (void)openRecentDocument:(NSMenuItem *)sender;

// Re-levels the About and Settings windows to match Settings.alwaysOnTop.
// They must ride at the player's level: left at normal level, the floating
// player would bury them — Settings being where the very checkbox that turns
// the mode off lives. MainPlayerController's applyAlwaysOnTop calls it on
// every change; the show methods apply it to a window created while the mode
// is already on.
- (void)applyAuxiliaryWindowLevels;

#if DEBUG
// The burst coalescer's queue depth for dump_health. Forwarded rather than
// exposing the coalescer, which is a private ivar here.
- (NSUInteger)debugQueuedOpenCount;
#endif
@end


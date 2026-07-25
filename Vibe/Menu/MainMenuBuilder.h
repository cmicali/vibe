//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class AppDelegate;
@class MainPlayerController;
@class OpenRecentMenuController;

NS_ASSUME_NONNULL_BEGIN

// Builds the app's menu bar — a stateless one-shot, so there is nothing to
// instantiate or keep alive. Every live submenu's delegate is owned by the
// object it works for and supplied here to be wired (Open Recent by the app
// delegate's OpenRecentMenuController, Output by the player's
// OutputDevicesMenuController, waveform Style by the player controller
// itself), and item validation lives with the items' targets
// (MainPlayerController+Menus).
@interface MainMenuBuilder : NSObject

// Builds the menu bar and sets it as NSApp.mainMenu (+ servicesMenu). Menu
// delegates are weak references, so openRecentMenuController must outlive the
// menu (the app delegate owns it).
+ (void)installMainMenuWithAppDelegate:(AppDelegate *)appDelegate
                      playerController:(MainPlayerController *)playerController
              openRecentMenuController:(OpenRecentMenuController *)openRecentMenuController;

@end

NS_ASSUME_NONNULL_END

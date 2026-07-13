//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class AppDelegate;
@class MainPlayerController;

NS_ASSUME_NONNULL_BEGIN

// Builds the app's menu bar (previously MainMenu.xib) and acts as the Open
// Recent submenu's delegate, so the app delegate must keep one alive for the
// app's lifetime.
@interface MainMenuBuilder : NSObject <NSMenuDelegate>

- (instancetype)initWithAppDelegate:(AppDelegate *)appDelegate
                   playerController:(MainPlayerController *)playerController;

// Builds the menu bar and sets it as NSApp.mainMenu (+ servicesMenu).
- (void)installMainMenu;

@end

NS_ASSUME_NONNULL_END

//
//  AppDelegate.h
//  Vibe
//
//  Created by Christopher Micali on 12/14/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) MainPlayerController *mainPlayerController;

- (IBAction)openDocument:(id)sender;
- (IBAction)showAboutWindow:(id)sender;

// Target of the Open Recent menu items OpenRecentMenuController creates.
- (void)openRecentDocument:(NSMenuItem *)sender;
@end


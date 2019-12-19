//
//  AppDelegate.m
//  Vibe
//
//  Created by Christopher Micali on 12/14/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "AppDelegate.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    
    [self.mainPlayerController showWindow:self];
    [self.mainPlayerController setSmallSize:NO];

}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {

}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    return NO;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {

}



@end

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

    id<DDLogger> osLogger = [DDOSLogger sharedInstance];
    [DDLog addLogger:osLogger withLevel:ddLogLevel];

    LogInfo(@"Vibe started");

    [self.mainPlayerController showWindow:self];
   // [self.mainPlayerController setSmallSize:NO];

}


- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    [self.mainPlayerController playURLs:urls];
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    [self.mainPlayerController playURL:[NSURL fileURLWithPath:filename]];
    return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    NSMutableArray *urls = [NSMutableArray arrayWithCapacity:filenames.count];
    for(NSString *file in filenames) {
        [urls addObject:[NSURL fileURLWithPath:file]];
    }
    [self.mainPlayerController playURLs:urls];
}



@end

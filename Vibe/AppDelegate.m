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

@implementation AppDelegate {
    BOOL _isLoaded;
    NSMutableArray<NSURL *> *_urlsToOpen;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _urlsToOpen = [[NSMutableArray alloc] init];
        _isLoaded = NO;
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {

    id<DDLogger> osLogger = [DDOSLogger sharedInstance];
    [DDLog addLogger:osLogger withLevel:ddLogLevel];

    LogInfo(@"Vibe started");

    [NSApplication sharedApplication].automaticCustomizeTouchBarMenuItemEnabled = YES;
    [[AppSettings sharedInstance] applicationDidFinishLaunching];

    [self.mainPlayerController showWindow:self];

    _isLoaded = YES;
    [self playURLs];
}

- (void)playURLs {
    if (_isLoaded && _urlsToOpen.count > 0) {
        WEAK_SELF dispatch_async(dispatch_get_main_queue(), ^{
            [self.mainPlayerController playURLs:weakSelf->_urlsToOpen];
            [weakSelf->_urlsToOpen removeAllObjects];
        });
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [self.mainPlayerController.audioPlayer rampVolumeToZero:NO];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    [_urlsToOpen addObjectsFromArray:urls];
    [self playURLs];
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    [_urlsToOpen addObject:[NSURL fileURLWithPath:filename]];
    [self playURLs];
    return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    for(NSString *file in filenames) {
        [_urlsToOpen addObject:[NSURL fileURLWithPath:file]];
    }
    [self playURLs];
}

@end

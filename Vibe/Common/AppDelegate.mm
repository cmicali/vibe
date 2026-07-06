//
//  AppDelegate.m
//  Vibe
//
//  Created by Christopher Micali on 12/14/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "AppDelegate.h"
#import "NSURLUtil.h"

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
        id<DDLogger> osLogger = [DDOSLogger sharedInstance];
        [DDLog addLogger:osLogger withLevel:ddLogLevel];
        LogInfo(@"Vibe starting");
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {

    LogInfo(@"Vibe started");

    [[AppSettings sharedInstance] applicationDidFinishLaunching];

    [self cleanupLegacyCaches];

    [self.mainPlayerController showWindow:self];

    _isLoaded = YES;
    [self playURLs];
}

// Superseded cache formats can hold tens of MB that would otherwise linger
// for months; delete their directories once in the background.
- (void)cleanupLegacyCaches {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *cachesDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (!cachesDir) {
            return;
        }
        NSArray<NSString *> *legacyCacheNames = @[
                @"com.pinterest.PINDiskCache.Audio Track Metadata",
                @"com.pinterest.PINDiskCache.Audio Track Metadata v2",
                @"com.pinterest.PINDiskCache.audio_waveform_cache",
        ];
        for (NSString *name in legacyCacheNames) {
            [[NSFileManager defaultManager] removeItemAtPath:[cachesDir stringByAppendingPathComponent:name] error:nil];
        }
    });
}

- (void)playURLs {
    if (_isLoaded && _urlsToOpen.count > 0) {
        NSArray<NSURL*>* urls = [self->_urlsToOpen copy];
        [self->_urlsToOpen removeAllObjects];
        [NSURLUtil expandAndFilterList:urls completion:^(NSArray<NSURL *> *expanded) {
            // Nothing playable (e.g. a folder with no audio) — don't wipe the
            // current playlist with an empty list.
            if (expanded.count > 0) {
                [self.mainPlayerController play:expanded];
            }
        }];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // [self.mainPlayerController.audioPlayer rampVolumeToZero:NO];
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

- (IBAction)openDocument:(id)sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowedFileTypes = VIBE_SUPPORTED_FILETYPES;
    [panel beginWithCompletionHandler:^(NSInteger result){
        if (result == NSModalResponseOK) {
            [self->_urlsToOpen addObjectsFromArray:panel.URLs];
            [self performSelectorOnMainThread:@selector(playURLs) withObject:nil waitUntilDone:NO];
        }
    }];
}

@end

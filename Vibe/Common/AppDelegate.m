//
//  AppDelegate.m
//  Vibe
//
//  Created by Christopher Micali on 12/14/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "AppDelegate.h"
#import "MainPlayerController.h"
#import "NSURLUtil.h"
#import "AboutWindowController.h"
#import "MainMenuBuilder.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#if DEBUG
#import "DebugUtil.h"
#endif

@interface AppDelegate ()

@property (nonatomic, strong) AboutWindowController *aboutWindowController;

@end


@implementation AppDelegate {
    BOOL _isLoaded;
    NSMutableArray<NSURL *> *_urlsToOpen;
    MainMenuBuilder *_menuBuilder;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _urlsToOpen = [[NSMutableArray alloc] init];
        _isLoaded = NO;
        LogInfo(@"Vibe starting");
    }
    return self;
}

#pragma mark - Launch

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    // The main nib used to instantiate the controller and the menu bar; both
    // are built here now, early enough for window state restoration (which
    // runs before applicationDidFinishLaunching) to find the controller.
    self.mainPlayerController = [[MainPlayerController alloc] init];
    _menuBuilder = [[MainMenuBuilder alloc] initWithAppDelegate:self
                                               playerController:self.mainPlayerController];
    [_menuBuilder installMainMenu];
}

// Target of the Open Recent items MainMenuBuilder creates.
- (void)openRecentDocument:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    if (url) {
        [_urlsToOpen addObject:url];
        [self playURLs];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {

    LogInfo(@"Vibe started");

    [[AppSettings sharedInstance] applicationDidFinishLaunching];

#if DEBUG
    VibeInstallDebugScreenshotHook();
    VibeInstallDebugCommandHook();
#endif

    [self cleanupLegacyCaches];

    [self.mainPlayerController showWindow:self];

    [self openCommandLineArguments];

    _isLoaded = YES;
    [self playURLs];
}

// Open file/directory paths passed as command-line arguments, e.g.
//     Vibe.app/Contents/MacOS/Vibe ~/Music/album /path/to/song.flac
// Paths resolve relative to the working directory and feed the same
// expand/filter/play pipeline as dropped files and Finder opens (directories
// are walked, unsupported files dropped). Dash-prefixed flags are skipped,
// and each candidate must exist on disk. NOTE: under the App Sandbox this
// only succeeds for paths the sandbox already permits (the container, or
// files opened via Launch Services / drag) — arbitrary argv paths may be
// denied at read time.
- (void)openCommandLineArguments {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSUInteger i = 1; i < args.count; i++) { // skip argv[0] (the executable)
        NSString *arg = args[i];
        if ([arg isEqualToString:@"--debug-cmd"]) {
            i++; // the only flag that takes a value (see main.m)
            continue;
        }
        if ([arg hasPrefix:@"-"]) {
            // Skip only the flag itself: unconditionally consuming the next
            // arg would drop the path in `Vibe --someflag song.mp3`. A value
            // riding an AppKit "-key value" pair fails the exists check below.
            continue;
        }
        NSString *path = arg.stringByExpandingTildeInPath;
        if ([fileManager fileExistsAtPath:path]) {
            [_urlsToOpen addObject:[NSURL fileURLWithPath:path]];
            LogInfo(@"Opening command-line path: %@", path);
        }
    }
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
                @"com.pinterest.PINDiskCache.Audio Track Metadata v3",
                @"com.pinterest.PINDiskCache.audio_waveform_cache",
                @"com.pinterest.PINDiskCache.audio_waveform_cache_v2",
                @"com.pinterest.PINDiskCache.audio_waveform_cache_v3",
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

// LaunchServices can split one multi-file open into several openURLs:
// events (seen reliably right after a rebuild re-registers the bundle).
// play: REPLACES the playlist, so acting on each event separately keeps
// only the last event's files. Coalesce a burst into a single play.
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    [_urlsToOpen addObjectsFromArray:urls];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(playURLs) object:nil];
    [self performSelector:@selector(playURLs) withObject:nil afterDelay:0.3];
}

- (IBAction)showAboutWindow:(id)sender {
    if (!self.aboutWindowController) {
        self.aboutWindowController = [[AboutWindowController alloc] init];
    }
    [self.aboutWindowController showWindow:sender];
}

- (IBAction)openDocument:(id)sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    // Derive the selectable types from the CFBundleDocumentTypes declarations
    // in Info.plist so the open panel can't drift from what Launch Services
    // registers the app for.
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray new];
    NSArray *documentTypes = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDocumentTypes"];
    for (NSDictionary *documentType in documentTypes) {
        for (NSString *identifier in documentType[@"LSItemContentTypes"]) {
            UTType *type = [UTType typeWithIdentifier:identifier];
            if (type) {
                [contentTypes addObject:type];
            }
        }
    }
    // An empty allowlist would make every file unselectable; fall back to
    // no filter if the plist declarations ever go missing.
    if (contentTypes.count > 0) {
        panel.allowedContentTypes = contentTypes;
    }
    [panel beginWithCompletionHandler:^(NSInteger result){
        if (result == NSModalResponseOK) {
            [self->_urlsToOpen addObjectsFromArray:panel.URLs];
            [self performSelectorOnMainThread:@selector(playURLs) withObject:nil waitUntilDone:NO];
        }
    }];
}

@end

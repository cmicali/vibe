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
#import "OpenRecentMenuController.h"
#import "NSBundle+BuildInfo.h"
#import "DocumentTypes.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/sysctl.h>

#if DEBUG
#import "DebugUtil.h"
#endif

@interface AppDelegate () <NSMenuItemValidation>

@property (nonatomic, strong) AboutWindowController *aboutWindowController;

@end


// How long after an open event the next one still counts as part of the same
// burst; see openQueuedURLs. It is long enough to absorb a split multi-file
// open, and short enough that a deliberate second open replaces rather than
// appends.
static const NSTimeInterval kOpenBurstQuietPeriod = 0.3;

@implementation AppDelegate {
    BOOL _isLoaded;
    NSMutableArray<NSURL *> *_urlsToOpen;
    // A batch has already played, and further batches belong with it, so they
    // append rather than replace. endOpenBurst clears this after the quiet
    // period.
    BOOL _openBurstActive;
    // The Open Recent submenu's delegate. It is owned here because menu
    // delegates are weak, and this object is the target of the items it
    // creates.
    OpenRecentMenuController *_openRecentMenuController;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _urlsToOpen = [[NSMutableArray alloc] init];
        _isLoaded = NO;
        LogInfo(@"Vibe %@ starting", NSBundle.mainBundle.vibeVersionString);
    }
    return self;
}

#pragma mark - Launch

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    // Build the controller and menu bar early enough that window state
    // restoration, which runs before applicationDidFinishLaunching, can find
    // the controller.
    self.mainPlayerController = [[MainPlayerController alloc] init];
    _openRecentMenuController = [[OpenRecentMenuController alloc] initWithAppDelegate:self];
    [MainMenuBuilder installMainMenuWithAppDelegate:self
                                   playerController:self.mainPlayerController
                           openRecentMenuController:_openRecentMenuController];
}

// The target of the Open Recent items OpenRecentMenuController creates.
- (void)openRecentDocument:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    if (url) {
        [_urlsToOpen addObject:url];
        [self playURLs];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {

    LogInfo(@"     _ _          \n__ _(_) |__  ___  \n\\ V / | '_ \\/ -_) \n \\_/|_|_.__/\\___| \n\n");
    LogInfo(@"Vibe %@ started", NSBundle.mainBundle.vibeVersionString);
    [self logBuildInfo];

    [[AppSettings sharedInstance] applicationDidFinishLaunching];

#if DEBUG
    VibeInstallDebugScreenshotHook();
    VibeInstallDebugCommandHook();
#endif

    [self cleanupLegacyCaches];

    [self.mainPlayerController showWindow:self];

    [self openCommandLineArguments];

    _isLoaded = YES;
    if (_urlsToOpen.count > 0) {
        // Through the burst path, because the post-launch remainder of an open
        // that straddled launch must append rather than replace.
        [self openQueuedURLs];
    }
    else {
        // No launch-time open is queued, since Finder and argv events land
        // before this point, so the empty state may render.
        [self.mainPlayerController revealEmptyState];
    }
}

// Everything known about how this binary was built, plus the OS it landed on,
// so that a log excerpt identifies the build it came from without guesswork.
- (void)logBuildInfo {
    NSBundle *bundle = NSBundle.mainBundle;
    LogInfo(@"    Source: %@", bundle.vibeGitString);
    LogInfo(@"     Built: %@", bundle.vibeBuildTimeString);
#if SHOW_EXTENDED_BUILD_INFO
    LogInfo(@"Compiler:  %@", bundle.vibeCompilerString);
    LogInfo(@"Flags:     %@", bundle.vibeBuildFlagsString);
    LogInfo(@"Toolchain: %@", bundle.vibeToolchainString);
    // operatingSystemVersionString is documented as unsuitable for parsing,
    // and reads "Version 26.5.1 (Build 25F80)", so the version comes from the
    // struct and the build from sysctl.
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    char osBuild[32] = "?";
    size_t osBuildSize = sizeof(osBuild);
    sysctlbyname("kern.osversion", osBuild, &osBuildSize, NULL, 0);
    LogInfo(@"Host:      macOS %ld.%ld.%ld (%s)", os.majorVersion, os.minorVersion, os.patchVersion, osBuild);
#endif
}

// Opens file and directory paths passed as command-line arguments, as in:
//     Vibe.app/Contents/MacOS/Vibe ~/Music/album /path/to/song.flac
// Paths resolve relative to the working directory and feed the same expand,
// filter and play pipeline as dropped files and Finder opens, so directories
// are walked and unsupported files dropped. Dash-prefixed flags are skipped,
// and each candidate must exist on disk.
//
// Note that under the App Sandbox this succeeds only for paths the sandbox
// already permits — the container, or files opened through Launch Services or
// a drag — so an arbitrary argv path may be denied at read time.
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
            // Skip only the flag itself. Consuming the next argument
            // unconditionally would drop the path in
            // `Vibe --someflag song.mp3`. A value riding an AppKit
            // "-key value" pair fails the exists check below.
            continue;
        }
        NSString *path = arg.stringByExpandingTildeInPath;
        if ([fileManager fileExistsAtPath:path]) {
            [_urlsToOpen addObject:[NSURL fileURLWithPath:path]];
            LogInfo(@"Opening command-line path: %@", path);
        }
    }
}

// Superseded cache formats can hold tens of MB that would otherwise linger for
// months, so delete their directories once, in the background.
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

// A replacing play of everything queued: the ⌘O panel and Open Recent entry
// point.
- (void)playURLs {
    _openBurstActive = NO; // a deliberate open ends any Finder burst
    [self openQueuedURLsAppending:NO];
}

// Expands the queue, walking folders and dropping unsupported files, and hands
// the result to the controller, either appended or as a replacing play.
- (void)openQueuedURLsAppending:(BOOL)append {
    if (!_isLoaded || _urlsToOpen.count == 0) {
        return;
    }
    NSArray<NSURL*>* urls = [_urlsToOpen copy];
    [_urlsToOpen removeAllObjects];
    [NSURLUtil expandAndFilterList:urls completion:^(NSArray<NSURL *> *expanded) {
        // Nothing playable, as with a folder that holds no audio. Do not wipe
        // the current playlist with an empty list.
        if (expanded.count == 0) {
            // A launch open that resolved to nothing must still end the launch
            // grace, or the header would stay blank forever.
            [self.mainPlayerController revealEmptyState];
            return;
        }
        if (append) {
            [self.mainPlayerController addURLs:expanded];
        }
        else {
            [self.mainPlayerController play:expanded];
        }
    }];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

// Launch Services can split one multi-file open into several openURLs: events.
// It happens reliably right after a rebuild re-registers the bundle.
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    [_urlsToOpen addObjectsFromArray:urls];
    [self openQueuedURLs];
}

// The Finder and Launch Services entry point, including at launch time, since
// a burst can straddle applicationDidFinishLaunching. The first batch plays
// immediately, with no coalescing delay, and later batches of the same burst
// append, so a split multi-file open lands as one playlist without restarting
// the first track.
- (void)openQueuedURLs {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(endOpenBurst) object:nil];
    [self performSelector:@selector(endOpenBurst) withObject:nil afterDelay:kOpenBurstQuietPeriod];
    if (!_isLoaded || _urlsToOpen.count == 0) {
        return; // pre-launch: applicationDidFinishLaunching drains the queue
    }
    BOOL append = _openBurstActive;
    _openBurstActive = YES;
    [self openQueuedURLsAppending:append];
}

- (void)endOpenBurst {
    _openBurstActive = NO;
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
    // The selectable types are the CFBundleDocumentTypes declarations from
    // Info.plist, so the open panel cannot drift from what Launch Services
    // registers the app for.
    NSArray<UTType *> *contentTypes = DocumentTypes.declaredTypes;
    // An empty allowlist would make every file unselectable, so fall back to
    // no filter should the plist declarations ever go missing.
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

#pragma mark - Default app

// Vibe > Set Vibe as Default Music Player claims every audio type declared in
// Info.plist at once, sparing the user Finder's Get Info > Open With > Change
// All once per extension. There is no alert of our own on either outcome: the
// system runs its own confirmation panel, and says so when it refuses, and the
// menu item retitles itself on the next validation pass.
- (IBAction)makeDefaultMusicPlayer:(id)sender {
    [DocumentTypes makeDefaultApp];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem.identifier isEqualToString:@"menu_make_default_app"]) {
        // There is nothing to do once Vibe already holds every type, so say so
        // in the title and disable the item rather than offer a no-op.
        BOOL isDefault = DocumentTypes.isDefaultAppForAllFileTypes;
        menuItem.title = isDefault ? @"Vibe Is the Default Music Player"
                                   : @"Set Vibe as Default Music Player";
        return !isDefault;
    }
    return YES;
}

@end

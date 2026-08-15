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
#import "SettingsWindowController.h"
#import "MainMenuBuilder.h"
#import "OpenBurstCoalescer.h"
#import "OpenRequestCoordinator.h"
#import "OpenRecentMenuController.h"
#import "NSBundle+BuildInfo.h"
#import "AppStats.h"
#import "DocumentTypes.h"
#import "FolderAccessManager.h"
#import "FolderArtResolver.h"
#import "VibeStrings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/sysctl.h>

#if DEBUG
#import "DebugUtil.h"
#endif

@interface AppDelegate ()

@property (nonatomic, strong) AboutWindowController *aboutWindowController;
@property (nonatomic, strong) SettingsWindowController *settingsWindowController;

@end


// How long after an open event the next one still counts as part of the same
// burst. It is long enough to absorb a split multi-file open, and short
// enough that a deliberate second open replaces rather than appends.
static const NSTimeInterval kOpenBurstQuietPeriod = 0.3;

@implementation AppDelegate {
    // Burst coalescing — replace vs append, the quiet period, the pre-launch
    // queue — lives in the coalescer; this object supplies the sink that
    // expands and plays each drained batch.
    OpenBurstCoalescer *_openBurstCoalescer;
    // The Open Recent submenu's delegate. It is owned here because menu
    // delegates are weak, and this object is the target of the items it
    // creates.
    OpenRecentMenuController *_openRecentMenuController;
    // The live ⌘O panel, so repeated opens re-front it instead of stacking
    // independent panels whose completions each do a replacing play.
    NSOpenPanel *_openPanel;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        __weak __typeof(self) weakSelf = self;
        _openBurstCoalescer = [[OpenBurstCoalescer alloc]
                initWithQuietPeriod:kOpenBurstQuietPeriod
                               sink:^(NSArray<NSURL *> *urls, BOOL append) {
                                   [weakSelf openURLs:urls appending:append];
                               }];
        LogInfo(@"Vibe %@ starting", NSBundle.mainBundle.vibeVersionString);
    }
    return self;
}

#pragma mark - Launch

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    // A playlist file's entries live outside the grant opening it conferred,
    // so the expansion may have to ask for their folder. The asking is this
    // layer's — the panel and the bookmark are the sandbox-grant funnel — and
    // the expansion only signals that it is needed. Installed before any open
    // can run.
    [NSURLUtil setPlaylistFolderGrantHandler:^BOOL(NSURL *playlistURL) {
        return [[FolderAccessManager sharedInstance] requestAccessForPlaylistFolder:playlistURL];
    }];
    // An expansion walks folders anyway, so the folder-artwork resolver takes
    // its answers from that walk rather than paying for a listing of its own.
    // Wired here for the same reason as the grant above: the expansion finds
    // the facts, but acting on them belongs to the app layer.
    [NSURLUtil setWalkedDirectoriesHandler:^(NSSet<NSString *> *directories,
                                             NSDictionary<NSString *, NSString *> *artFilenameByDirectory) {
        [FolderArtResolver.sharedInstance noteListedDirectories:directories
                                     artFilenameByDirectory:artFilenameByDirectory];
    }];
    [NSURLUtil setBulkOpenDirectoriesHandler:^(NSSet<NSString *> *directories) {
        [FolderArtResolver.sharedInstance preferListingForDirectories:directories];
    }];
    // Build the controller and menu bar early enough that window state
    // restoration, which runs before applicationDidFinishLaunching, can find
    // the controller.
    self.mainPlayerController = [[MainPlayerController alloc] init];
    _openRecentMenuController = [[OpenRecentMenuController alloc] initWithAppDelegate:self];
    [MainMenuBuilder installMainMenuWithAppDelegate:self
                                   playerController:self.mainPlayerController
                           openRecentMenuController:_openRecentMenuController];
}

// The app opts into window restoration (NSQuitAlwaysKeepsWindows); without
// this, AppKit uses legacy insecure decoding for the restorable state.
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

// The target of the Open Recent items OpenRecentMenuController creates.
- (void)openRecentDocument:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    if (url) {
        [_openBurstCoalescer openReplacingURLs:@[url]];
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

    // A launch-time open of a remembered folder (Open Recent, restored state)
    // may depend on a restored grant, so the queue drains only once the
    // grants are back — bounded, see restoreGrantedAccessWithCompletion:.
    // Opens that land in the meantime queue in the coalescer.
    [[FolderAccessManager sharedInstance] restoreGrantedAccessWithCompletion:^{
        if (![self->_openBurstCoalescer startAndDrainQueue]) {
            // No launch-time open is queued: Finder events land before this
            // point, so the empty state may render. Argv paths arrive a beat
            // later, off their exists checks, and replace it as a burst open.
            [self.mainPlayerController revealEmptyState];
        }
    }];
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
    // The exists checks run off the main thread: a stat can block for an
    // automounter timeout on an unreachable mount, and this is launch time.
    // The survivors race the deferred launch drain, so they enter through
    // openBurstURLs:, which queues before start and drains after it either
    // way.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (NSUInteger i = 1; i < args.count; i++) {
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
                [urls addObject:[NSURL fileURLWithPath:path]];
                LogInfo(@"Opening command-line path: %@", path);
            }
        }
        if (urls.count == 0) {
            return;
        }
        run_on_main_thread({
            [self->_openBurstCoalescer openBurstURLs:urls];
        });
    });
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

// The coalescer's sink: expands a drained batch, walking folders and dropping
// unsupported files, and hands the result to the controller, either appended
// or as a replacing play.
- (void)openURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append {
    __weak AppDelegate *weakSelf = self;
    OpenRequestToken *token = [OpenRequestCoordinator.sharedCoordinator
            beginRequestAppending:append
                         delivery:^(NSArray<NSURL *> *files, NSUInteger folders, BOOL appending) {
                             [weakSelf deliverExpandedURLs:files folderCount:folders appending:appending];
                         }];
    // If this batch is under a remembered folder whose grant is still being
    // restored, wait for that scope — bounded; see the method's declaration.
    [[FolderAccessManager sharedInstance] awaitRestoredAccessForURLs:urls completion:^{
        [weakSelf openURLsWithRestoredAccess:urls token:token];
    }];
}

- (void)openURLsWithRestoredAccess:(NSArray<NSURL *> *)urls token:(OpenRequestToken *)token {
    if (![OpenRequestCoordinator.sharedCoordinator isRequestCurrent:token]) {
        return;
    }
    // Folders arrive here holding a live sandbox grant; bookmark them now so
    // the grant survives relaunch (see FolderAccessManager).
    [[FolderAccessManager sharedInstance] noteOpenedURLs:urls];
    [NSURLUtil expandAndFilterList:urls completion:^(NSArray<NSURL *> *expanded, NSUInteger folderCount) {
        [OpenRequestCoordinator.sharedCoordinator finishRequest:token
                                                          files:expanded
                                                    folderCount:folderCount];
    }];
}

- (void)deliverExpandedURLs:(NSArray<NSURL *> *)expanded
                folderCount:(NSUInteger)folderCount
                  appending:(BOOL)append {
    [[AppStats sharedInstance] recordOpenedFiles:expanded.count folders:folderCount];
    // Nothing playable, as with a folder that holds no audio. Do not wipe the
    // current playlist with an empty list.
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
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    // Persist the in-progress listening run; quitting fires no player callback.
    [[AppStats sharedInstance] playbackStopped];
}

// Launch Services can split one multi-file open into several openURLs: events.
// It happens reliably right after a rebuild re-registers the bundle. The
// coalescer lands a split open as one playlist without restarting the first
// track.
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    [_openBurstCoalescer openBurstURLs:urls];
}

- (IBAction)showAboutWindow:(id)sender {
    if (!self.aboutWindowController) {
        self.aboutWindowController = [[AboutWindowController alloc] init];
    }
    [self applyAuxiliaryWindowLevels];
    [self.aboutWindowController showWindow:sender];
}

- (IBAction)showSettingsWindow:(id)sender {
    if (!self.settingsWindowController) {
        self.settingsWindowController = [[SettingsWindowController alloc]
                initWithPlayerController:self.mainPlayerController];
    }
    [self applyAuxiliaryWindowLevels];
    [self.settingsWindowController showWindow:sender];
}

- (void)applyAuxiliaryWindowLevels {
    NSWindowLevel level = Settings.alwaysOnTop ? NSFloatingWindowLevel : NSNormalWindowLevel;
    self.aboutWindowController.window.level = level;
    self.settingsWindowController.window.level = level;
}

- (IBAction)openDocument:(id)sender {
    if (_openPanel) {
        [_openPanel makeKeyAndOrderFront:sender];
        return;
    }
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
    _openPanel = panel;
    [panel beginWithCompletionHandler:^(NSInteger result){
        self->_openPanel = nil;
        if (result == NSModalResponseOK) {
            [self->_openBurstCoalescer openReplacingURLs:panel.URLs];
        }
    }];
}

#if DEBUG
- (NSUInteger)debugQueuedOpenCount {
    return [_openBurstCoalescer debugQueuedURLCount];
}
#endif

@end

//
//  AppDelegate.m
//  Vibe
//

#import "AppDelegate.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioFileConverter.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Devices.h"
#import "MainPlayerController.h"
#import "NSURLUtil.h"
#import "AboutWindowController.h"
#import "SettingsWindowController.h"
#import "MainMenuBuilder.h"
#import "OpenBurstCoalescer.h"
#import "OpenRequestCoordinator.h"
#import "OpenRecentMenuController.h"
#import "PlaylistFile.h"
#import "NSBundle+BuildInfo.h"
#import "AppStats.h"
#import "VibeProductURLs.h"
#import "DocumentTypes.h"
#import "FolderAccessManager.h"
#import "FolderAccessManager+GrantPanel.h"
#import "FolderArtResolver.h"
#import "VibeStrings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#if DEBUG
#import "DebugUtil.h"
#import "OpenBurstCoalescer+Debug.h"
#endif


@interface AppDelegate ()

@property (nonatomic, strong) AboutWindowController *aboutWindowController;
@property (nonatomic, strong) SettingsWindowController *settingsWindowController;

@end


// Long enough to absorb a split multi-file open, short enough that a
// deliberate second open replaces rather than appends.
static const NSTimeInterval kOpenBurstQuietPeriod = 0.3;

@implementation AppDelegate {
    OpenBurstCoalescer *_openBurstCoalescer;
    // Owned here because menu delegates are weak.
    OpenRecentMenuController *_openRecentMenuController;
    // Repeated ⌘O re-fronts it rather than stacking panels that each replace.
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
    // Installed before any open can run. The walk reports; acting on it
    // (the grant panel, folder art) belongs to the app layer.
    [NSURLUtil setPlaylistFolderGrantHandler:^BOOL(NSURL *playlistURL) {
        return [[FolderAccessManager sharedInstance] requestAccessForPlaylistFolder:playlistURL];
    }];
    [NSURLUtil setWalkedDirectoriesHandler:^(NSSet<NSString *> *directories,
                                             NSDictionary<NSString *, NSString *> *artFilenameByDirectory) {
        [FolderArtResolver.sharedInstance noteListedDirectories:directories
                                     artFilenameByDirectory:artFilenameByDirectory];
    }];
    [NSURLUtil setBulkOpenDirectoriesHandler:^(NSSet<NSString *> *directories) {
        [FolderArtResolver.sharedInstance preferListingForDirectories:directories];
    }];
    // Window state restoration runs before applicationDidFinishLaunching.
    self.mainPlayerController = [[MainPlayerController alloc] init];
    _openRecentMenuController = [[OpenRecentMenuController alloc] initWithAppDelegate:self];
    [MainMenuBuilder installMainMenuWithAppDelegate:self
                                   playerController:self.mainPlayerController
                           openRecentMenuController:_openRecentMenuController];
}

// Without this, AppKit uses legacy insecure decoding for restorable state.
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

- (void)openRecentDocument:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    if (url) {
        [_openBurstCoalescer openDeliberateURLs:@[url] appending:NO];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {

    LogInfo(@"     _ _          \n__ _(_) |__  ___  \n\\ V / | '_ \\/ -_) \n \\_/|_|_.__/\\___| \n\n");
    LogInfo(@"Vibe %@ started", NSBundle.mainBundle.vibeVersionString);
    VibeLogBuildProvenance();

    [[AppSettings sharedInstance] applicationDidFinishLaunching];

#if DEBUG
    VibeInstallDebugScreenshotHook();
    VibeInstallDebugCommandHook();
#endif

    [self cleanupLegacyCaches];

    [self.mainPlayerController showWindow:self];

    [self openCommandLineArguments];

    // A launch-time open may need a restored grant, so the coalescer's queue
    // drains only once the grants are back (bounded).
    [[FolderAccessManager sharedInstance] restoreGrantedAccessWithCompletion:^{
        // A launch-time open outranks the remembered playlist, and the restore
        // is not an open (Mac/App/AGENTS.md).
        [self->_openBurstCoalescer finishLaunchRestoring:^BOOL{
            return [self.mainPlayerController restoreLastPlaylist];
        } revealEmpty:^{
            [self.mainPlayerController revealEmptyStateNamingPlaylist:nil];
        }];
    }];
}

// Dash-prefixed flags are skipped. Under the sandbox only paths it already
// permits are readable, so an arbitrary argv path may be denied at read time.
- (void)openCommandLineArguments {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    // Off main: a stat can block for an automounter timeout. The survivors
    // race the launch drain; openBurstURLs: queues before start either way.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSURL *> *urls = [OpenBurstCoalescer fileURLsInArguments:args existingPath:^BOOL(NSString *path) {
            return [NSFileManager.defaultManager fileExistsAtPath:path];
        }];
        if (urls.count == 0) {
            return;
        }
        run_on_main_thread({
            [self->_openBurstCoalescer openBurstURLs:urls];
        });
    });
}

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
                @"com.pinterest.PINDiskCache.audio_waveform_cache_v4",
        ];
        for (NSString *name in legacyCacheNames) {
            [[NSFileManager defaultManager] removeItemAtPath:[cachesDir stringByAppendingPathComponent:name] error:nil];
        }
    });
}

- (void)openDroppedURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append {
    [_openBurstCoalescer openDeliberateURLs:urls appending:append];
}

// The coalescer's sink.
- (void)openURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append {
    // An empty batch must not mint a token: it would supersede the open in
    // flight and reveal the empty state over it.
    if (urls.count == 0) {
        return;
    }
    __weak AppDelegate *weakSelf = self;
    OpenRequestToken *token = [OpenRequestCoordinator.sharedCoordinator
            beginRequestAppending:append
                         delivery:^(NSArray<AudioTrack *> *rows, NSUInteger folders, BOOL appending) {
                             [weakSelf deliverExpandedRows:rows folderCount:folders appending:appending
                                                  fromURLs:urls];
                         }];
    [[FolderAccessManager sharedInstance] awaitRestoredAccessForURLs:urls completion:^{
        [weakSelf openURLsWithRestoredAccess:urls token:token];
    }];
}

- (void)openURLsWithRestoredAccess:(NSArray<NSURL *> *)urls token:(OpenRequestToken *)token {
    if (![OpenRequestCoordinator.sharedCoordinator isRequestCurrent:token]) {
        return;
    }
    // Bookmark while the open's sandbox grant is live.
    [[FolderAccessManager sharedInstance] noteOpenedURLs:urls];
    // Read on main; the walk reads no setting itself.
    [NSURLUtil expandAndFilterList:urls
                          sortedBy:AppSettings.sharedInstance.folderOpenSort
                        completion:^(NSArray<AudioTrack *> *rows, NSUInteger folderCount) {
        [OpenRequestCoordinator.sharedCoordinator finishRequest:token
                                                           rows:rows
                                                    folderCount:folderCount];
    }];
}

- (void)deliverExpandedRows:(NSArray<AudioTrack *> *)rows
                folderCount:(NSUInteger)folderCount
                  appending:(BOOL)append
                   fromURLs:(NSArray<NSURL *> *)urls {
    [[AppStats sharedInstance] recordOpenedFiles:rows.count folders:folderCount];
    // Nothing playable must not wipe the playlist. The empty header names an
    // opened playlist, extension kept so it reads as the sheet rather than its
    // album, and the launch grace ends, or the header would stay blank.
    if (rows.count == 0) {
        NSString *playlist = nil;
        for (NSURL *url in urls) {
            if ([PlaylistFile isPlaylistExtension:url.pathExtension.lowercaseString]) {
                playlist = url.lastPathComponent;
                break;
            }
        }
        [self.mainPlayerController revealEmptyStateNamingPlaylist:playlist];
        return;
    }
    if (append) {
        [self.mainPlayerController addTracks:rows];
    }
    else {
        [self.mainPlayerController play:rows];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

// A quit waits on the device (restoring its format and hog, bounded at 1.5 s)
// and on a conversion's cancel, so Vibe leaves the screen first and finishes
// off main.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    for (NSWindow *window in NSApp.windows) {
        [window orderOut:nil];
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    dispatch_group_t owed = dispatch_group_create();
    AudioFileConverter *converter = self.mainPlayerController.fileConverter;
    if (converter.isConverting) {
        dispatch_group_enter(owed);
        [converter cancelConversionWithCompletion:^{
            dispatch_group_leave(owed);
        }];
    }
    // The player is never deallocated, so this is what restores the device.
    AudioPlayer *player = self.mainPlayerController.audioPlayer;
    player.delegate = nil; // no auto-advance while the cleanup waits for its queue
    dispatch_group_async(owed, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [player prepareForTermination];
    });
    // TRAP: never reply through the main dispatch queue. A quit issued from a
    // main-queue block runs terminate:'s wait loop inside it, libdispatch does
    // not drain the main queue re-entrantly, and the reply never runs. The run
    // loop's block queue is serviced by that wait loop.
    dispatch_group_notify(owed, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
            [sender replyToApplicationShouldTerminate:YES];
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    });
    return NSTerminateLater;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    // Persist the in-progress listening run; quitting fires no player callback.
    [[AppStats sharedInstance] playbackStopped];
    [self.mainPlayerController saveLastPlaylist];
}

// Launch Services can split one multi-file open into several events.
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

- (IBAction)showThemeSettings:(id)sender {
    [self showSettingsWindow:sender];
    [self.settingsWindowController showThemeEditor];
}

- (IBAction)showSupportPage:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kVibeSupportURL]];
}

- (void)applyAuxiliaryWindowLevels {
    NSWindowLevel level = AppSettings.sharedInstance.alwaysOnTop ? NSFloatingWindowLevel : NSNormalWindowLevel;
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
    NSArray<UTType *> *contentTypes = DocumentTypes.declaredTypes;
    // An empty allowlist would make every file unselectable.
    if (contentTypes.count > 0) {
        panel.allowedContentTypes = contentTypes;
    }
    _openPanel = panel;
    [panel beginWithCompletionHandler:^(NSInteger result){
        self->_openPanel = nil;
        if (result == NSModalResponseOK) {
            [self->_openBurstCoalescer openDeliberateURLs:panel.URLs appending:NO];
        }
    }];
}

#if DEBUG
- (NSUInteger)debugQueuedOpenCount {
    return [_openBurstCoalescer debugQueuedURLCount];
}
#endif

@end

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
#import "AudioTrack.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Playlist.h"
#import "MainPlayerController+Settings.h"
#import "FolderWalk.h"
#import "AboutWindowController.h"
#import "SettingsWindowController.h"
#import "MainMenuBuilder.h"
#import "OpenBurstCoalescer.h"
#import "OpenRequestCoordinator.h"
#import "OpenLinkWindowController.h"
#import "OpenRecentMenuController.h"
#import "PlaylistController.h"
#import "PlaylistFile.h"
#import "NSBundle+BuildInfo.h"
#import "AppStats.h"
#import "VibeProductURLs.h"
#import "DocumentTypes.h"
#import "FolderAccessManager.h"
#import "FolderAccessManager+GrantPanel.h"
#import "FolderArtResolver.h"
#import "FolderArtRules.h"
#import "LegacyCacheStores.h"
#import "LinkDropRules.h"
#import "LinkStore.h"
#import "StringRules.h"
#import "VibeStrings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#if VIBE_DIRECT_DISTRIBUTION
#import "VibeUpdater.h"
#endif

#if DEBUG
#import "DebugCommonVerbs.h"
#import "DebugMacEntry.h"
#import "OpenBurstCoalescer+Debug.h"
#import "OpenLinkWindowController+Debug.h"
#endif


@interface AppDelegate () <NSMenuItemValidation>

@property (nonatomic, strong) AboutWindowController *aboutWindowController;
@property (nonatomic, strong) SettingsWindowController *settingsWindowController;

@end


// Long enough to absorb a split multi-file open, short enough that a
// deliberate second open replaces rather than appends.
static const NSTimeInterval kOpenBurstQuietPeriod = 0.3;

// TRAP: a shipped key. Another spelling forgets every grant.
static NSString *const kGrantedFoldersDefaultsKey = @"VibeGrantedFolders";

#if VIBE_DIRECT_DISTRIBUTION
// A Debug build starts the updater only with --update-feed, and checks only
// the feed it names. So the debug channel, stress runs and screenshots never
// raise an update dialog. nil keeps the Info.plist's feed.
static NSString *DebugUpdateFeed(void) {
#if DEBUG
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSUInteger index = [args indexOfObject:@"--update-feed"];
    return index != NSNotFound && index + 1 < args.count ? args[index + 1] : nil;
#else
    return nil;
#endif
}
#endif

// Launch work the first window does not need runs half a second after it.
// TRAP: dispatch_async is not enough. A main-queue block queued during launch
// can still run before the window is up.
static void VibeAfterLaunch(dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), block);
}

@implementation AppDelegate {
    OpenBurstCoalescer *_openBurstCoalescer;
    // Owned here because menu delegates are weak.
    OpenRecentMenuController *_openRecentMenuController;
    // Open and Add to Playlist re-front one panel rather than stacking panels.
    // The command chosen last sets its button and whether it appends.
    NSOpenPanel *_openPanel;
    BOOL _openPanelAppends;
    OpenLinkWindowController *_openLinkWindowController;
    // One cancel per open still resolving its links, until it settles.
    NSMutableArray<dispatch_block_t> *_linkOpenCancels;
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
        _linkOpenCancels = [NSMutableArray array];
        _folderAccessManager = [[FolderAccessManager alloc] initWithDefaults:NSUserDefaults.standardUserDefaults
                                                                         key:kGrantedFoldersDefaultsKey];
        LogInfo(@"Vibe %@ starting", NSBundle.mainBundle.vibeVersionString);
    }
    return self;
}

#pragma mark - Launch

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    // Before the player exists, so every play-path error carries the app's domain.
    VibeAudioErrorSetDomain(NSBundle.mainBundle.bundleIdentifier);
#if DEBUG
    // Before the player exists too, which reads its debug output when it
    // makes it.
    VibeDebugApplyLaunchFlags();
#endif
    // Before the restore, which may name a link. From here a link's
    // placeholder is dataless, and opening it streams it.
    [LinkStore.shared installAsRemoteBackend];
    FolderAccessManager *folderAccess = self.folderAccessManager;
    // Folder art asks the app whether it is on and whether a folder's grant
    // covers a directory, so the resolver reads no setting or grant itself.
    [FolderArtResolver.sharedInstance setEnabledProvider:^BOOL{
        return AppSettings.sharedInstance.useFolderArt;
    } accessProvider:^BOOL(NSString *directory) {
        return [folderAccess canReadInsideDirectory:directory];
    }];
    // Installed before any open can run. The walk reports; acting on it
    // (the grant panel, folder art) belongs to the app layer.
    [FolderWalk setPlaylistFolderGrantHandler:^BOOL(NSURL *playlistURL) {
        NSString *message = [NSString stringWithFormat:STR_PLAYLIST_GRANT_MESSAGE,
                                                       VibeAppName(), playlistURL.lastPathComponent];
        return [folderAccess requestAccessForPlaylistFolder:playlistURL
                                                    message:message
                                                     prompt:STR_PLAYLIST_GRANT_BUTTON];
    }];
    // The walk ranks each file it lists by folder art's cover rank.
    [FolderWalk setWalkedFileHandler:^NSUInteger(NSString *filename) {
        return VibeFolderArtCandidateRank(filename);
    }];
    [FolderWalk setWalkedDirectoriesHandler:^(NSSet<NSString *> *directories,
                                             NSDictionary<NSString *, NSString *> *keptFilenameByDirectory) {
        [FolderArtResolver.sharedInstance noteListedDirectories:directories
                                     artFilenameByDirectory:keptFilenameByDirectory];
    }];
    [FolderWalk setBulkOpenDirectoriesHandler:^(NSSet<NSString *> *directories) {
        [FolderArtResolver.sharedInstance preferListingForDirectories:directories];
    }];
#if VIBE_DIRECT_DISTRIBUTION
    // Before the menu, whose Check for Updates… targets it.
    _updater = [[VibeUpdater alloc] initWithFeedURLString:DebugUpdateFeed() betaUpdates:^BOOL {
        return AppSettings.sharedInstance.receiveBetaUpdates;
    }];
#endif
    // Window state restoration runs before applicationDidFinishLaunching.
    self.mainPlayerController = [[MainPlayerController alloc] init];
    _openRecentMenuController = [[OpenRecentMenuController alloc] initWithAppDelegate:self];
    _openLinkWindowController = [[OpenLinkWindowController alloc] initWithAppDelegate:self];
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

    VibeRemoveLegacyCacheStoresOffMain();

    [self.mainPlayerController showWindow:self];

    // The key equivalents read the keyboard layout through TIS. No key reaches
    // a menu before the window is up.
    VibeAfterLaunch(^{
        [self.mainPlayerController applySettingsLiveEffects:VibeSettingsLiveEffectShortcuts];
    });

#if VIBE_DIRECT_DISTRIBUTION
#if DEBUG
    if (DebugUpdateFeed()) {
        [_updater start];
    }
#else
    [_updater start];
#endif
#endif

    [self openCommandLineArguments];

    // A launch-time open may need a restored grant, so the coalescer's queue
    // drains only once the grants are back (bounded).
    [self.folderAccessManager restoreGrantedAccessWithCompletion:^{
        // A launch-time open outranks the remembered playlist, and the restore
        // is not an open (Mac/App/AGENTS.md).
        [self->_openBurstCoalescer finishLaunchRestoring:^BOOL{
            return [self.mainPlayerController restoreLastPlaylist]
                || [self.mainPlayerController loadWelcomeTrack];
        } revealEmpty:^{
            [self.mainPlayerController revealEmptyStateNamingPlaylist:nil];
        }];
        // The recent documents are a round trip to the system's store.
        VibeAfterLaunch(^{
            [self pruneLinks];
        });
    }];
}

// Once per launch, after the restore, so the playlist holds what it brought
// back. A launch-time open may still be expanding, so its rows are not kept.
// A link it names was opened within 30 days, unless a saved playlist names an
// older one.
- (void)pruneLinks {
    [LinkStore.shared pruneKeepingTracks:self.mainPlayerController.playlistController.playlist
                              recentURLs:NSDocumentController.sharedDocumentController.recentDocumentURLs];
}

// Dash-prefixed flags are skipped. Under the sandbox only paths it already
// permits are readable, so an arbitrary argv path may be denied at read time.
- (void)openCommandLineArguments {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    // Off main: a stat can block for an automounter timeout. The survivors
    // race the launch drain; openBurstURLs: queues before start either way.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // The debug channel's command is the argument after its flag.
        NSArray<NSURL *> *urls = [OpenBurstCoalescer fileURLsInArguments:args
                                                            valueOptions:[NSSet setWithObject:@"--debug-cmd"]
                                                            existingPath:^BOOL(NSString *path) {
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
    OpenRequestToken *token = [self beginOpenRequestAppending:append fromURLs:urls];
    if (VibeDropHasLinks(urls)) {
        [self openLinksAmongURLs:urls appending:append token:token];
    }
    else {
        [self openFiles:urls token:token];
    }
}

- (void)openFiles:(NSArray<NSURL *> *)urls token:(OpenRequestToken *)token {
    __weak AppDelegate *weakSelf = self;
    [self.folderAccessManager awaitRestoredAccessForURLs:urls completion:^{
        [weakSelf openURLsWithRestoredAccess:urls token:token];
    }];
}

// A drop holding links (Loading/Net/AGENTS.md). Each .webloc is read for
// its link off main, then the drop opens in drop order.
- (void)openLinksAmongURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append token:(OpenRequestToken *)token {
    [self.mainPlayerController beginLinkResolveFeedbackAppending:append];
    [self openInOrder:^NSArray *{
        return VibeDropOpenOrder(urls, ^NSData *(NSURL *webloc) {
            NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:webloc error:NULL];
            NSData *head = [handle readDataUpToLength:kVibeLinkWeblocMaxBytes error:NULL];
            [handle closeAndReturnError:NULL];
            return head;
        });
    } token:token completion:nil];
}

// The one road a link opens by, a drop's and Open URL's. order runs off
// main and answers what opens: file URLs, and links as NSURLs or typed text.
// Each link resolves in that order, one at a time. The files and the links'
// files then open as one open, in that order. A link that fails drops out,
// and the header shows the first failure. A cancel, or a newer replacing
// open, opens nothing. Completion on main, before the header shows the
// failure, with what opened and the first failure. Returns the cancel, on
// main.
- (dispatch_block_t)openInOrder:(NSArray *(^)(void))order
                          token:(OpenRequestToken *)token
                     completion:(nullable void (^)(NSArray<NSURL *> *files, NSError *_Nullable error))completion {
    __weak AppDelegate *weakSelf = self;
    // Held while the links resolve. A later open that finishes first must
    // not give up on this one at the straggler deadline.
    [OpenRequestCoordinator.sharedCoordinator holdRequest:token];
    __block BOOL cancelled = NO;
    __block dispatch_block_t cancelResolve = nil;
    dispatch_block_t cancel = ^{
        cancelled = YES;
        // A resolve's cancel completes it at once, which clears the variable.
        dispatch_block_t resolve = cancelResolve;
        if (resolve) {
            resolve();
        }
    };
    [_linkOpenCancels addObject:cancel];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *items = order();
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray<NSURL *> *files = [NSMutableArray array];
            __block NSError *firstError = nil;
            __block NSString *status = nil;
            __block NSString *failed = nil;
            __block void (^step)(NSUInteger) = nil;
            step = ^(NSUInteger next) {
                AppDelegate *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                BOOL current = !cancelled && [OpenRequestCoordinator.sharedCoordinator isRequestCurrent:token];
                while (current && next < items.count && [items[next] isKindOfClass:NSURL.class]
                       && [items[next] isFileURL]) {
                    [files addObject:items[next++]];
                }
                if (current && next < items.count) {
                    id item = items[next];
                    NSString *text = [item isKindOfClass:NSURL.class] ? [item absoluteString] : item;
                    cancelResolve = [LinkStore.shared resolveURLString:text
                                                            completion:^(NSURL *file, NSError *error) {
                        cancelResolve = nil;
                        if (file) {
                            [files addObject:file];
                        }
                        else {
                            firstError = firstError ?: error;
                            if (!status) {
                                status = VibeLinkMessageForError(error, YES);
                                failed = VibeLinkNameOfText(text);
                            }
                        }
                        void (^again)(NSUInteger) = step;
                        again(next + 1);
                    }];
                    return;
                }
                [strongSelf->_linkOpenCancels removeObjectIdenticalTo:cancel];
                OpenRequestCoordinator *coordinator = OpenRequestCoordinator.sharedCoordinator;
                [coordinator releaseRequest:token];
                if (![coordinator isRequestCurrent:token]) {
                    // Superseded: nothing delivers for this open, so a
                    // drop's shimmer ends here.
                    [strongSelf endLinkResolveFeedbackIfIdle];
                }
                else if (!current || files.count == 0) {
                    // The empty delivery. It leaves a loaded playlist as it
                    // is. Over an empty one it ends the launch grace.
                    [coordinator finishRequest:token rows:@[] folderCount:0];
                }
                else {
                    [strongSelf openFiles:files token:token];
                }
                if (completion) {
                    completion(files, firstError);
                }
                if (current && status) {
                    [strongSelf.mainPlayerController showNotice:status naming:failed];
                }
                // Last: this block may go with it.
                step = nil;
            };
            void (^first)(NSUInteger) = step;
            first(0);
        });
    });
    return cancel;
}

// After the last link drop settles. A delivery while another drop resolves
// leaves its shimmer up.
- (void)endLinkResolveFeedbackIfIdle {
    if (_linkOpenCancels.count == 0) {
        [self.mainPlayerController endLinkResolveFeedback];
    }
}

- (BOOL)cancelLinkOpens {
    NSArray<dispatch_block_t> *cancels = [_linkOpenCancels copy];
    for (dispatch_block_t cancel in cancels) {
        cancel();
    }
    return cancels.count > 0;
}

// Every open, files and Open URL… alike, mints its token here.
- (OpenRequestToken *)beginOpenRequestAppending:(BOOL)append fromURLs:(NSArray<NSURL *> *)urls {
    [self.mainPlayerController spendWelcomeTrack];
    __weak AppDelegate *weakSelf = self;
    OpenRequestToken *token = [OpenRequestCoordinator.sharedCoordinator
            beginRequestAppending:append
                         delivery:^(NSArray<AudioTrack *> *rows, NSUInteger folders, BOOL appending) {
                             [weakSelf deliverExpandedRows:rows folderCount:folders appending:appending
                                                  fromURLs:urls];
                         }];
    // After the supersession, so a superseded open delivers nothing. Its
    // links stop resolving.
    if (!append) {
        [self cancelLinkOpens];
    }
    // The newer open's header must not wait for a held link error.
    [self.mainPlayerController endNotice];
    return token;
}

- (dispatch_block_t)openLinkString:(NSString *)string completion:(void (^)(NSURL *, NSError *))completion {
    OpenRequestToken *token = [self beginOpenRequestAppending:NO fromURLs:@[]];
    return [self openInOrder:^NSArray *{
        return @[string];
    } token:token completion:^(NSArray<NSURL *> *files, NSError *error) {
        if (!completion) {
            return;
        }
        // Superseded before its resolve began, it settles as a cancel.
        completion(files.firstObject, files.count ? nil : error ?: [NSError errorWithDomain:VibeLinkErrorDomain
                                                                                       code:VibeLinkErrorCancelled
                                                                                   userInfo:nil]);
    }];
}

- (void)openURLsWithRestoredAccess:(NSArray<NSURL *> *)urls token:(OpenRequestToken *)token {
    if (![OpenRequestCoordinator.sharedCoordinator isRequestCurrent:token]) {
        return;
    }
    // Bookmark while the open's sandbox grant is live.
    [self.folderAccessManager noteOpenedURLs:urls];
    // Read on main; the walk reads no setting itself. The rows are made on
    // the expansion worker, off main.
    [FolderWalk expandAndFilterList:urls
                           sortedBy:AppSettings.sharedInstance.folderOpenSort
                         completion:^(NSArray<PlaylistEntry *> *entries, NSUInteger folderCount) {
        NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:entries];
        run_on_main_thread({
            [OpenRequestCoordinator.sharedCoordinator finishRequest:token
                                                               rows:rows
                                                        folderCount:folderCount];
        });
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
    }
    else if (append) {
        [self.mainPlayerController addTracks:rows];
    }
    else {
        [self.mainPlayerController play:rows];
    }
    // After the play, which takes the strip for its own open. A drop
    // superseded by this open ends here too.
    [self endLinkResolveFeedbackIfIdle];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

// A quit waits on device cleanup and a conversion's cancellation. HAL calls
// can block, so Vibe leaves the screen before waiting off main.
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
    _openLinkWindowController.window.level = level;
}

- (IBAction)openDocument:(id)sender {
    [self showOpenPanelAppending:NO];
}

- (IBAction)addToPlaylist:(id)sender {
    [self showOpenPanelAppending:YES];
}

- (void)showOpenPanelAppending:(BOOL)append {
    _openPanelAppends = append;
    NSOpenPanel *panel = _openPanel ?: [NSOpenPanel openPanel];
    panel.prompt = append ? STR_BUTTON_ADD : STR_BUTTON_OPEN;
    if (panel == _openPanel) {
        [panel makeKeyAndOrderFront:nil];
        return;
    }
    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    NSArray<UTType *> *declaredTypes = DocumentTypes.declaredTypes;
    NSMutableOrderedSet<UTType *> *contentTypes = [NSMutableOrderedSet orderedSetWithArray:declaredTypes];
    // TRAP: another app's type for an extension need not conform to ours.
    // Include every registered type for each declared extension.
    for (UTType *type in declaredTypes) {
        for (NSString *extension in type.tags[UTTagClassFilenameExtension]) {
            [contentTypes addObjectsFromArray:[UTType typesWithTag:extension
                                                         tagClass:UTTagClassFilenameExtension
                                                 conformingToType:nil]];
        }
    }
    // An empty allowlist would make every file unselectable.
    if (contentTypes.count > 0) {
        panel.allowedContentTypes = contentTypes.array;
    }
    _openPanel = panel;
    [panel beginWithCompletionHandler:^(NSInteger result){
        self->_openPanel = nil;
        if (result == NSModalResponseOK) {
            [self->_openBurstCoalescer openDeliberateURLs:panel.URLs appending:self->_openPanelAppends];
        }
    }];
}

- (IBAction)openLink:(id)sender {
    [_openLinkWindowController showWindow:sender];
}

// ⌘W and Close's validation with no window ahead of this one to take them.
- (IBAction)closeFile:(id)sender {
    [_openLinkWindowController closeFile:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    return [_openLinkWindowController validateMenuItem:menuItem];
}

#if DEBUG
- (NSUInteger)debugQueuedOpenCount {
    return [_openBurstCoalescer debugQueuedURLCount];
}

- (NSWindow *)debugOpenLinkWindow {
    return _openLinkWindowController.window;
}

- (BOOL)debugOpenLinkResolving {
    return [_openLinkWindowController debugResolving];
}
#endif

@end

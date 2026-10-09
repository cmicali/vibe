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
#import "NSURLUtil.h"
#import "AboutWindowController.h"
#import "SettingsWindowController.h"
#import "MainMenuBuilder.h"
#import "MenuValidationRules.h"
#import "OpenBurstCoalescer.h"
#import "OpenRequestCoordinator.h"
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
#import "LinkStore.h"
#import "VibeStrings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#if DEBUG
#import "DebugUtil.h"
#import "OpenBurstCoalescer+Debug.h"
#endif


@interface AppDelegate () <NSMenuItemValidation, NSWindowDelegate, NSTextFieldDelegate>

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
    // Open URL's window and its controls while it is up. A second ⌘U
    // re-fronts it.
    NSPanel *_openLinkWindow;
    NSTextField *_openLinkField;
    NSButton *_openLinkButton;
    NSProgressIndicator *_openLinkSpinner;
    // Cancels the window's link while it resolves.
    dispatch_block_t _cancelOpenLink;
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
        LogInfo(@"Vibe %@ starting", NSBundle.mainBundle.vibeVersionString);
    }
    return self;
}

#pragma mark - Launch

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    // Before the restore, which may name a link. From here a link's
    // placeholder is dataless, and opening it streams it.
    [LinkStore.shared installAsRemoteBackend];
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
    // Any first launch spends the welcome track, even one a launch-time open
    // or a restore pre-empts; only Factory reset re-arms it.
    BOOL firstLaunch = !AppSettings.sharedInstance.welcomeTrackLoaded;
    AppSettings.sharedInstance.welcomeTrackLoaded = YES;
    [[FolderAccessManager sharedInstance] restoreGrantedAccessWithCompletion:^{
        // A launch-time open outranks the remembered playlist, and the restore
        // is not an open (Mac/App/AGENTS.md).
        [self->_openBurstCoalescer finishLaunchRestoring:^BOOL{
            return [self.mainPlayerController restoreLastPlaylist]
                || (firstLaunch && [self.mainPlayerController loadWelcomeTrack]);
        } revealEmpty:^{
            [self.mainPlayerController revealEmptyStateNamingPlaylist:nil];
        }];
        [self pruneLinks];
    }];
}

// Once per launch, after the restore, so the playlist holds what it brought
// back. A launch-time open may still be expanding, so its rows are not kept.
// A link it names was opened within 30 days, unless a saved playlist names an
// older one.
- (void)pruneLinks {
    NSMutableArray<NSURL *> *rows = [NSMutableArray array];
    for (AudioTrack *track in self.mainPlayerController.playlistController.playlist) {
        if (track.url) {
            [rows addObject:track.url];
        }
    }
    NSArray<NSURL *> *recents = NSDocumentController.sharedDocumentController.recentDocumentURLs;
    [LinkStore.shared pruneKeepingURLs:VibeLinkKeptURLs(rows, recents)];
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
    [[FolderAccessManager sharedInstance] awaitRestoredAccessForURLs:urls completion:^{
        [weakSelf openURLsWithRestoredAccess:urls token:token];
    }];
}

// A drop holding links (System/Remote/AGENTS.md). Each .webloc is read for
// its link off main. Then each link resolves in drop order, one at a time.
// The files and the links' files open as one open, in drop order. A link
// that fails drops out, and the header shows the first failure. A cancel, or
// a newer replacing open, opens nothing.
- (void)openLinksAmongURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append token:(OpenRequestToken *)token {
    __weak AppDelegate *weakSelf = self;
    [self.mainPlayerController beginLinkResolveFeedbackAppending:append];
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
        NSArray<NSURL *> *order = VibeDropOpenOrder(urls, ^NSData *(NSURL *webloc) {
            NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:webloc error:NULL];
            NSData *head = [handle readDataUpToLength:kVibeLinkWeblocMaxBytes error:NULL];
            [handle closeAndReturnError:NULL];
            return head;
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray<NSURL *> *files = [NSMutableArray array];
            __block NSString *status = nil;
            __block NSString *failed = nil;
            __block void (^step)(NSUInteger) = nil;
            step = ^(NSUInteger next) {
                AppDelegate *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                BOOL current = !cancelled && [OpenRequestCoordinator.sharedCoordinator isRequestCurrent:token];
                while (current && next < order.count && order[next].isFileURL) {
                    [files addObject:order[next++]];
                }
                if (current && next < order.count) {
                    cancelResolve = [LinkStore.shared resolveURLString:order[next].absoluteString
                                                            completion:^(NSURL *file, NSError *error) {
                        cancelResolve = nil;
                        if (file) {
                            [files addObject:file];
                        }
                        else if (!status) {
                            status = [LinkStore messageForError:error brief:YES];
                            failed = VibeLinkNameOfText(order[next].absoluteString);
                        }
                        void (^again)(NSUInteger) = step;
                        again(next + 1);
                    }];
                    return;
                }
                [strongSelf->_linkOpenCancels removeObjectIdenticalTo:cancel];
                if (!current || files.count == 0) {
                    // The empty delivery, as an Open URL failure's.
                    [OpenRequestCoordinator.sharedCoordinator finishRequest:token rows:@[] folderCount:0];
                }
                else {
                    [strongSelf openFiles:files token:token];
                }
                if (current && status) {
                    [strongSelf.mainPlayerController showOpenError:status naming:failed];
                }
                // Last: this block may go with it.
                step = nil;
            };
            void (^first)(NSUInteger) = step;
            first(0);
        });
    });
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

- (OpenRequestToken *)beginOpenRequestAppending:(BOOL)append fromURLs:(NSArray<NSURL *> *)urls {
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
    [self.mainPlayerController endOpenError];
    return token;
}

- (dispatch_block_t)openLinkString:(NSString *)string completion:(void (^)(NSURL *, NSError *))completion {
    OpenRequestToken *token = [self beginOpenRequestAppending:NO fromURLs:@[]];
    __weak AppDelegate *weakSelf = self;
    return [LinkStore.shared resolveURLString:string completion:^(NSURL *file, NSError *error) {
        if (file) {
            [weakSelf openURLsWithRestoredAccess:@[file] token:token];
        }
        else {
            // Nothing to open: the empty delivery. It leaves a loaded
            // playlist as it is. Over an empty one it ends the launch grace.
            [OpenRequestCoordinator.sharedCoordinator finishRequest:token rows:@[] folderCount:0];
        }
        if (completion) {
            completion(file, error);
        }
        // After the completion, which closes the window. A newer open or
        // Close leaves the header alone.
        NSString *status = error ? [LinkStore messageForError:error brief:YES] : nil;
        if (status && [OpenRequestCoordinator.sharedCoordinator isRequestCurrent:token]) {
            [weakSelf.mainPlayerController showOpenError:status naming:VibeLinkNameOfText(string)];
        }
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
    _openLinkWindow.level = level;
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
            [self->_openBurstCoalescer openDeliberateURLs:panel.URLs appending:NO];
        }
    }];
}

// Its own window, not a sheet, so the player keeps working while it is up.
// It stays up when Vibe is not active, since the link is often copied from a
// browser.
- (IBAction)openLink:(id)sender {
    NSWindow *player = self.mainPlayerController.window;
    [player makeKeyAndOrderFront:sender];
    if (_openLinkWindow) {
        [_openLinkWindow makeKeyAndOrderFront:sender];
        [_openLinkWindow makeFirstResponder:_openLinkField];
        return;
    }
    const CGFloat width = 480;
    const CGFloat margin = 20;
    NSTextField *label = [NSTextField labelWithString:STR_LINK_PROMPT_LABEL];
    NSTextField *field = [NSTextField textFieldWithString:@""];
    field.placeholderString = VibeNotLocalized(@"https://");
    field.usesSingleLineMode = NO;
    field.cell.wraps = YES;
    field.cell.scrollable = NO;
    field.lineBreakMode = NSLineBreakByCharWrapping;
    field.delegate = self;
    NSButton *open = [NSButton buttonWithTitle:STR_BUTTON_OPEN target:self action:@selector(confirmOpenLink:)];
    open.keyEquivalent = @"\r";
    open.enabled = NO;
    NSButton *cancel = [NSButton buttonWithTitle:STR_BUTTON_CANCEL target:self action:@selector(cancelOpenLink:)];
    cancel.keyEquivalent = @"\e";
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] init];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.displayedWhenStopped = NO;
    [spinner sizeToFit];
    [open sizeToFit];
    [cancel sizeToFit];

    // Bottom up: the buttons at the right, the spinner beside them, a field
    // three lines tall, and its label.
    CGFloat buttonWidth = MAX(MAX(NSWidth(open.frame), NSWidth(cancel.frame)), 80);
    CGFloat buttonHeight = NSHeight(open.frame);
    open.frame = NSMakeRect(width - margin - buttonWidth, margin, buttonWidth, buttonHeight);
    cancel.frame = NSOffsetRect(open.frame, -(buttonWidth + 12), 0);
    NSSize spin = spinner.frame.size;
    spinner.frame = NSMakeRect(NSMinX(cancel.frame) - 10 - spin.width,
                               margin + (buttonHeight - spin.height) / 2, spin.width, spin.height);
    CGFloat lineHeight = [[[NSLayoutManager alloc] init] defaultLineHeightForFont:field.font];
    field.frame = NSMakeRect(margin, NSMaxY(open.frame) + margin, width - 2 * margin, ceil(3 * lineHeight) + 6);
    [label sizeToFit];
    label.frame = NSMakeRect(margin, NSMaxY(field.frame) + 6, NSWidth(label.frame), NSHeight(label.frame));

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, NSMaxY(label.frame) + margin)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                  backing:NSBackingStoreBuffered
                                                    defer:YES];
    panel.title = STR_LINK_PROMPT_TITLE;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    panel.delegate = self;
    panel.initialFirstResponder = field;
    for (NSView *view in @[label, field, spinner, cancel, open]) {
        [panel.contentView addSubview:view];
    }
    NSRect frame = panel.frame;
    frame.origin = NSMakePoint(round(NSMidX(player.frame) - NSWidth(frame) / 2),
                               round(NSMidY(player.frame) - NSHeight(frame) / 2));
    [panel setFrame:[panel constrainFrameRect:frame toScreen:player.screen] display:NO];
    _openLinkWindow = panel;
    _openLinkField = field;
    _openLinkButton = open;
    _openLinkSpinner = spinner;
    [self applyAuxiliaryWindowLevels];
    [panel makeKeyAndOrderFront:sender];
}

// Open is enabled only with a link in the field. The window stays up until
// the link settles. Its field and Open are disabled, and its spinner turns.
- (void)confirmOpenLink:(id)sender {
    _openLinkField.enabled = NO;
    _openLinkButton.enabled = NO;
    [_openLinkSpinner startAnimation:nil];
    __weak AppDelegate *weakSelf = self;
    _cancelOpenLink = [self openLinkString:_openLinkField.stringValue completion:^(NSURL *file, NSError *error) {
        AppDelegate *strongSelf = weakSelf;
        // A cancel's window is already gone.
        if (strongSelf && (file || [LinkStore messageForError:error brief:YES])) {
            strongSelf->_cancelOpenLink = nil;
            [strongSelf->_openLinkWindow close];
        }
    }];
}

// Cancel, Escape, and ⌘.: the window closes, which cancels the resolve.
- (void)cancelOpenLink:(id)sender {
    [_openLinkWindow close];
}

// ⌘W while the window is key. As its delegate, this catches the nil-targeted
// closeFile: ahead of the player's, which clears the playlist.
- (IBAction)closeFile:(id)sender {
    [_openLinkWindow performClose:sender];
}

// The player may have retitled the shared item "Close All Files".
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem.identifier isEqualToString:kVibeMenuClose]) {
        menuItem.title = STR_MENU_FILE_CLOSE;
        return _openLinkWindow.isKeyWindow;
    }
    return YES;
}

// Every way the window goes ends here. A link still resolving stops, and
// nothing opens.
- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object != _openLinkWindow) {
        return;
    }
    dispatch_block_t cancel = _cancelOpenLink;
    _cancelOpenLink = nil;
    _openLinkWindow = nil;
    _openLinkField = nil;
    _openLinkButton = nil;
    _openLinkSpinner = nil;
    if (cancel) {
        cancel();
    }
}

// A link has no line breaks, so a paste's are dropped.
- (void)controlTextDidChange:(NSNotification *)notification {
    NSText *editor = _openLinkField.currentEditor;
    NSString *text = editor.string;
    NSString *joined = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@""];
    if (joined.length != text.length) {
        editor.string = joined;
    }
    _openLinkButton.enabled = !VibeLinkTextIsBlank(joined);
}

// Return presses Open, with or without a modifier, and never breaks the line.
// Escape and ⌘. arrive as cancelOperation:, which would otherwise complete.
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (selector == @selector(insertNewline:) || selector == @selector(insertNewlineIgnoringFieldEditor:)
            || selector == @selector(insertLineBreak:)) {
        [_openLinkButton performClick:nil];
        return YES;
    }
    if (selector == @selector(cancelOperation:)) {
        [self cancelOpenLink:control];
        return YES;
    }
    return NO;
}

#if DEBUG
- (NSUInteger)debugQueuedOpenCount {
    return [_openBurstCoalescer debugQueuedURLCount];
}

- (NSWindow *)debugOpenLinkWindow {
    return _openLinkWindow;
}

- (BOOL)debugOpenLinkResolving {
    return _cancelOpenLink != nil;
}
#endif

@end

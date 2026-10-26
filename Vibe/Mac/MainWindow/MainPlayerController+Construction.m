//
//  MainPlayerController+Construction.m
//  Vibe
//
//  The app's construction road: the window, the real player, the metadata
//  scan, the OS publishers and the wiring between them. The host-less suite
//  does not compile it. It builds the controller through the injected
//  initializer instead.
//

#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Delivery.h"
#import "MainPlayerController+NowPlaying.h"
#import "MainPlayerController+PlayerEvents.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Transport.h"
#import "MainPlayerController+Window.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "ArtworkDisplayController.h"
#import "AudioAnalysisObservers.h"
#import "AudioFileConverter.h"
#import "AudioPlayer.h"
#import "AudioPlayer+BitPerfect.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "CloudTransferRegistry.h"
#import "FolderAccessManager.h"
#import "FolderArtResolver.h"
#import "MainPlayerContentView.h"
#import "NowPlayingController.h"
#import "OutputDevicesMenuController.h"
#import "PlaylistController.h"
#import "PlaylistTableView.h"
#import "TrackDisplayController.h"
#import "TransportKeyMonitor.h"
#import "UIUpdateTimer.h"
#import "UIUpdateMath.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme+Settings.h"
#import "WaveformView.h"
#if DEBUG
#import "DebugCommonVerbs.h"
#endif

@implementation MainPlayerController (Construction)

- (instancetype)init {
    // No nib: initWithWindow: marks the controller loaded, so AppKit never
    // runs loadWindow or windowDidLoad and both happen here.
    MainWindow *window = [[MainWindow alloc] init];
    VibeScheduler scheduler = ^(NSTimeInterval delay, dispatch_block_t block) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), block);
    };
    // buildCollaborators makes the player and the scan.
    if ((self = [self initWithWindow:window audioPlayer:nil metadataCache:nil metadataScheduler:scheduler])) {
        _emptyStateSuppressed = YES; // before the first updateUI
        // windowDidLoad hands it the audio player.
        self.devicesMenuController = [[OutputDevicesMenuController alloc] init];
        [self buildContentInWindow:window];
        [self windowDidLoad];
    }
    return self;
}

- (void)windowDidLoad {
    // Capped: a dead removal registration pins its tracks for the window's
    // lifetime.
    self.window.undoManager.levelsOfUndo = 32;
    [self buildCollaborators];
    [self wireCollaboratorHandlers];
    [self registerGrantAndArtworkObservers];
    [self wireWindowAndViews];
    [self buildPitchPanel];

    [self.playlistController reloadAllTracks];
    [self updateUI];
    [self syncEqualizerActivity];

    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
        // macOS 13 has no -activate; calling it crashes at launch.
        [NSApp activateIgnoringOtherApps:NO];
    }
}

- (void)buildCollaborators {
    // The saved device resolves asynchronously (UID, then name): the HAL
    // sweep can stall on Bluetooth or an unavailable coreaudiod, and must
    // block neither the player queue nor first paint.
    self.audioPlayer = [[AudioPlayer alloc] initWithDeviceUID:AppSettings.sharedInstance.audioOutputDeviceUID
                                                     modelUID:AppSettings.sharedInstance.audioOutputDeviceModelUID
                                                         name:AppSettings.sharedInstance.audioOutputDeviceName
                                                     enableFX:AppSettings.sharedInstance.audioFXAllowed
                                                     delegate:self];
    self.audioPlayer.crossfadeMilliseconds = AppSettings.sharedInstance.effectiveCrossfadeMilliseconds;
    self.audioPlayer.declick = AppSettings.sharedInstance.declick;
    self.audioPlayer.volume = (float)AppSettings.sharedInstance.effectiveVolume;
    [self.audioPlayer setBitPerfectOutput:AppSettings.sharedInstance.bitPerfectOutput
                         exclusiveOutput:AppSettings.sharedInstance.exclusiveOutput
                              enableFX:AppSettings.sharedInstance.audioFXEnabled allowAnyDevice:AppSettings.sharedInstance.allowBitPerfectOnAnyDevice];
    self.devicesMenuController.audioPlayer = self.audioPlayer;

    self.metadataCache = [[AudioTrackMetadataCache alloc] init];
    self.metadataCache.delegate = self;

    self.waveformCache = [[AudioWaveformCache alloc] init];
    self.waveformCache.delegate = self;

    self.fileConverter = [[AudioFileConverter alloc] init];

    [CloudTransferRegistry.sharedRegistry addObserver:self];
    [self buildPlaylistController];

    _artworkController = [[ArtworkDisplayController alloc] initWithContentView:self.playerContentView];

    _keyMonitor = [[TransportKeyMonitor alloc] initWithController:self];

#if DEBUG
    // A test launch makes none, since the controller claims the system's
    // media slot.
    if (!VibeDebugLaunchNoNowPlaying())
#endif
    self.nowPlayingController = [[NowPlayingController alloc] initWithDelegate:self];
    // Before the launch restore, so a shuffled restore starts its order on the
    // saved row.
    [self pushTransportModesToPlaylist];

    __weak MainPlayerController *weakSelf = self;
    _uiTimer = [[UIUpdateTimer alloc] initWithHz:kVibeUIUpdateHzMin handler:^{
        [weakSelf updatePlaybackUI];
        // Reconciliation, not an edge: a play settlement dropped as stale
        // (submittedPlayIsCurrent:) reaches no updateUI, which would leave the
        // system card's playbackState wrong for the whole track. The
        // publisher's unchanged check makes this a per-tick comparison;
        // position advance alone is not dirty.
        [weakSelf updateNowPlaying];
    }];
}

- (void)wireCollaboratorHandlers {
    // Asked once per request, so a settings change lands on the next load.
    // The iOS card installs its own, tempo only.
    AudioWaveformObserver *tempo = AudioBPMAnalyzer.waveformObserver;
    AudioWaveformObserver *key = AudioKeyAnalyzer.waveformObserver;
    self.waveformCache.analysisProvider = ^VibeWaveformAnalysis{
        AppSettings *settings = AppSettings.sharedInstance;
        NSMutableArray<AudioWaveformObserver *> *observers = [NSMutableArray arrayWithCapacity:2];
        if (settings.analyzeBPM) {
            [observers addObject:tempo];
        }
        if (settings.analyzeKey) {
            [observers addObject:key];
        }
        return (VibeWaveformAnalysis){
            .bands = [WaveformRendererRegistry readsBandsForIdentifier:settings.currentTheme.waveformStyle],
            .observers = observers,
        };
    };
    _waveformAnalysisWanted = self.waveformCache.analysisProvider();

    // A track change mid-conversion stops the sweep at the next report.
    __weak MainPlayerController *weakControllerForConvert = self;
    self.fileConverter.progressHandler = ^(AudioTrack *track, double fraction) {
        MainPlayerController *strongSelf = weakControllerForConvert;
        if (strongSelf && track == [strongSelf displayedTrack]) {
            [strongSelf.trackDisplay setConvertSweepFraction:fraction];
        }
    };

    __weak MainPlayerController *weakControllerForArt = self;
    _artworkController.currentTrackProvider = ^AudioTrack *{
        return weakControllerForArt.playlistController.currentTrack;
    };
    _artworkController.artDidResolveHandler = ^{
        [weakControllerForArt updateUI];
    };
    // Fired only for a target-matched install, so the delivery race is closed.
    _artworkController.dominantColorDidChangeHandler = ^{
        MainPlayerController *strongSelf = weakControllerForArt;
        if (!strongSelf) {
            return;
        }
        strongSelf.waveformView.artworkThemeColor = strongSelf->_artworkController.dominantArtColor;
        [strongSelf refreshWaveformTheme];
    };
    _artworkController.transportBackdropDidChangeHandler = ^(BOOL dark, BOOL hasArtwork) {
        [weakControllerForArt.playerContentView setTransportBackdropDark:dark hasArtwork:hasArtwork];
    };
    self.playerContentView.appearanceChangedHandler = ^{
        MainPlayerController *strongSelf = weakControllerForArt;
        if (strongSelf) {
            [strongSelf->_artworkController refreshTintWashes];
            [strongSelf applyWindowBackground]; // its layer color is not dynamic
            // The Now Playing placeholder follows the appearance.
            [strongSelf updateNowPlaying];
        }
    };
}

// Grants are observed here, not in the Files pane, which may never open: a
// new grant can reveal covers the resolver declined for want of one.
- (void)registerGrantAndArtworkObservers {
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(grantedFoldersDidChange:)
                                               name:FolderAccessManagerDidChangeNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(folderArtDidResolve:)
                                               name:FolderArtDidResolveNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(thumbnailDidLoad:)
                                               name:AudioTrackMetadataThumbnailDidLoadNotification
                                             object:nil];
}

- (void)wireWindowAndViews {
    // Closing the player quits (windowWillClose:): with About open,
    // applicationShouldTerminateAfterLastWindowClosed never fires.
    self.window.delegate = self;

    [self applyStoredAppearance];
    [self applyAlwaysOnTop];
    [self applyWindowLock];
    [self applyAppIcon];

    self.waveformView.delegate = self;
    self.waveformView.themeProvider = ^WaveformTheme *(BOOL isDark, NSColor *artworkColor) {
        return [WaveformTheme themeForAppTheme:AppSettings.sharedInstance.currentTheme isDark:isDark
                                  artworkColor:artworkColor];
    };
    // Creates the renderer, so the first load finds one.
    [self applyWaveformSettings];

    MainWindow *window = (MainWindow *)self.window;
    window.dropDelegate = self;
}

@end

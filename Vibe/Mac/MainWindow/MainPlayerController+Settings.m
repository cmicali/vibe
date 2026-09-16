//
//  MainPlayerController+Settings.m
//  Vibe
//

#import "MainPlayerController+Settings.h"
#import "ArtworkDisplayController.h"
#import "PlaylistController.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Menus.h"
#import "MainPlayerController+NowPlaying.h"
#import "MainPlayerController+Transport.h"
#import "MainPlayerController+Window.h"
#import "MainWindow.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
#import "AudioWaveformView.h"
#import "Fonts.h"
#import "MainMenuBuilder.h"
#import "PlaylistTableView.h"
#import "MainPlayerContentView.h"
#import "PitchControlPanel.h"
#import "TrackDisplayController.h"

@implementation MainPlayerController (Settings)

// The theme's font choice, pushed into Fonts — which may not read a setting
// itself. Runs before label construction at launch and from the Fonts effect.
- (void)applyStoredFonts {
    [Fonts applyThemeFonts:AppSettings.sharedInstance.currentTheme];
}

- (void)applySettingsLiveEffects:(VibeSettingsLiveEffect)effects {
    NSAssert(NSThread.isMainThread, @"Settings live effects are main-thread only");
    AppSettings *settings = AppSettings.sharedInstance;

    if (effects & VibeSettingsLiveEffectAlwaysOnTop) {
        [self applyAlwaysOnTop];
    }
    if (effects & VibeSettingsLiveEffectTrafficLights) {
        [self applyTrafficLights];
    }
    if (effects & VibeSettingsLiveEffectAppIcon) {
        [self applyAppIcon];
    }
    if (effects & VibeSettingsLiveEffectTransportButtons) {
        [self.playerContentView applyThemedTransportButtons];
    }
    if (effects & VibeSettingsLiveEffectPitchRange) {
        [self applyPitchRange];
    }
    if (effects & VibeSettingsLiveEffectEndOfTrack) {
        [self applyEndOfTrackAction];
    }
    if (effects & VibeSettingsLiveEffectReopenLastPlaylist) {
        [self applyReopenLastPlaylist];
    }
    if (effects & VibeSettingsLiveEffectCrossfade) {
        self.audioPlayer.crossfadeMilliseconds = settings.effectiveCrossfadeMilliseconds;
    }
    if (effects & VibeSettingsLiveEffectBitPerfect) {
        BOOL bitPerfect = settings.bitPerfectOutput;
        if (bitPerfect) {
            // No varispeed under the mode: reset both the player and its
            // readout, then withdraw the panel through the one toggle, which
            // pins the siblings for the animation.
            self.audioPlayer.pitch = 0;
            _pitchPanel.pitch = 0;
            if (((MainWindow *)self.window).isPitchPanelShown) {
                [self togglePitchPanel:nil];
            }
            [self updateRateDependentUI];
            [self updateNowPlaying];
        }
        // The header's lock and the Settings caption redraw from
        // audioPlayerDidChangeBitPerfectReport: once this lands on the
        // player queue; reading the report here would show the previous one.
        [self.audioPlayer setBitPerfectOutput:bitPerfect exclusiveOutput:settings.exclusiveOutput];
    }
    if (effects & VibeSettingsLiveEffectUIUpdateRate) {
        [self syncUITimerRate];
    }
    // Reset changes appearance, style and colors together; settle their inputs
    // before either color refresh.
    if (effects & VibeSettingsLiveEffectWindowAppearance) {
        [self applyStoredAppearance];
    }
    if (effects & VibeSettingsLiveEffectWindowChrome) {
        [self applyWindowChrome];
    }
    if (effects & VibeSettingsLiveEffectFonts) {
        [self applyStoredFonts];
        // The re-style resets the title to base size, so the refit must
        // follow in the same branch, or a shrink-fitted title strands at
        // full size and truncated.
        [self.playerContentView applyThemedLabelFonts];
        [self.trackDisplay refitTitle];
    }
    if (effects & VibeSettingsLiveEffectPlaylistRowFills) {
        // PlaylistRowView reads its themed fill per draw, so a row-fill color
        // change needs only a repaint, never a cell rebuild.
        [self.playlistTableView enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
            rowView.needsDisplay = YES;
        }];
    }
    if (effects & VibeSettingsLiveEffectPlaylistBackground) {
        [self.playerContentView applyPlaylistBackground];
    }
    if (effects & VibeSettingsLiveEffectPlaylistAppearance) {
        [PlaylistTableView invalidateCellAttributes];
        [self.playerContentView applyPlaylistBackground];
        [self.playlistTableView applyThemedColumnVisibility];
        [self.playlistTableView reloadData];
    }
    if (effects & VibeSettingsLiveEffectWaveformStyle) {
        self.waveformView.waveformStyle = settings.currentTheme.waveformStyle;
    }
    if (effects & VibeSettingsLiveEffectWaveformTheme) {
        [self refreshWaveformTheme];
    }
    if (effects & VibeSettingsLiveEffectWaveformLevels) {
        [self.waveformView refreshWaveformLevels];
    }
    if (effects & VibeSettingsLiveEffectWindowTint) {
        [self refreshWindowTint];
    }
    if (effects & VibeSettingsLiveEffectTrackDisplay) {
        // Colors only — fonts are the Fonts effect's, so a color drag never
        // re-measures the title. Drop the content guards so unchanged strings
        // still repaint; the themed no-artwork placeholder re-applies here
        // for the same reason.
        [self.playerContentView applyThemedLabelColors];
        [self->_artworkController refreshDefaultArtwork];
        [self.trackDisplay resetRenderGuards];
        [self updateUI];
    }
    if (effects & VibeSettingsLiveEffectFolderArt) {
        [self refreshFolderArt];
    }
    if (effects & VibeSettingsLiveEffectConvertMenu) {
        [MainMenuBuilder applyConvertMenuVisibility];
    }
    if (effects & VibeSettingsLiveEffectFXControls) {
        if (!settings.audioFXAllowed) {
            self.lowKillBoostActive = NO;
            self.lowKillActive = NO;
            self.reverbSendActive = NO;
            self.delaySendActive = NO;
            self.shortDelaySendActive = NO;
        }
        [MainMenuBuilder applyFXMenuVisibility];
    }
}

@end

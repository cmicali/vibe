//
//  MainPlayerController+Settings.m
//  Vibe
//

#import "MainPlayerController+Settings.h"
#import "ArtworkDisplayController.h"
#import "PlaylistController.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Menus.h"
#import "MainPlayerController+Transport.h"
#import "MainPlayerController+Window.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
#import "AudioWaveformView.h"
#import "Fonts.h"
#import "MainMenuBuilder.h"
#import "PlaylistTableView.h"
#import "MainPlayerContentView.h"
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
    if (effects & VibeSettingsLiveEffectPitchRange) {
        [self applyPitchRange];
    }
    if (effects & VibeSettingsLiveEffectEndOfTrack) {
        [self applyEndOfTrackAction];
    }
    if (effects & VibeSettingsLiveEffectCrossfade) {
        self.audioPlayer.crossfadeMilliseconds = settings.crossfadeMilliseconds;
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
        if (!settings.audioFXEnabled) {
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

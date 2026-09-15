//
//  MainPlayerController+Transport.m
//  Vibe
//

#import "MainPlayerController+Transport.h"
#import "MainPlayerControllerInternal.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Devices.h"
#import "AudioPlayer+Seek.h"
#import "AudioFX.h"
#import "Formatters.h"
#import "VibeStrings.h"
#import "AudioTrack.h"
#import "PlaylistController.h"
#import "TrackDisplayController.h"
#import "TransportMath.h"

// The skip distances. When the track's tempo is known, through AudioTrack.bpm,
// a skip moves by whole bars of four beats, which is a fixed span of *file*
// time, so the jump stays on the musical grid at any pitch. The bar counts
// are the settings' base (4, 8 or 16), twice it and four times it. Without a
// tempo the fallback is a fixed wall-clock distance that does not scale with
// the base.
static const NSTimeInterval kSkipSeconds = 10.0;
static const NSTimeInterval kSkipMoreSeconds = 30.0;
static const NSTimeInterval kSkipMostSeconds = 60.0;

@implementation MainPlayerController (Transport)

static double SkipBaseBars(void) {
    NSInteger base = AppSettings.sharedInstance.skipBaseBars;
    return base > 0 ? (double)base : 8.0;
}

// The arithmetic is VibeSkipFileSeconds in TransportMath.h; this supplies the
// track's tempo and the current rate.
- (NSTimeInterval)skipFileSecondsForBars:(double)bars fallbackWallClockSeconds:(NSTimeInterval)wallSeconds {
    return VibeSkipFileSeconds(bars,
                               self.playlistController.currentTrack.bpm,
                               wallSeconds,
                               self.playbackRate);
}

- (IBAction)skipForward:(nullable id)sender {
    [self skipByFileSeconds:[self skipFileSecondsForBars:SkipBaseBars() fallbackWallClockSeconds:kSkipSeconds]];
}

- (IBAction)skipForwardMore:(nullable id)sender {
    [self skipByFileSeconds:[self skipFileSecondsForBars:SkipBaseBars() * 2 fallbackWallClockSeconds:kSkipMoreSeconds]];
}

- (IBAction)skipForwardMost:(nullable id)sender {
    [self skipByFileSeconds:[self skipFileSecondsForBars:SkipBaseBars() * 4 fallbackWallClockSeconds:kSkipMostSeconds]];
}

- (IBAction)skipBack:(nullable id)sender {
    [self skipByFileSeconds:-[self skipFileSecondsForBars:SkipBaseBars() fallbackWallClockSeconds:kSkipSeconds]];
}

- (IBAction)skipBackMore:(nullable id)sender {
    [self skipByFileSeconds:-[self skipFileSecondsForBars:SkipBaseBars() * 2 fallbackWallClockSeconds:kSkipMoreSeconds]];
}

- (IBAction)skipBackMost:(nullable id)sender {
    [self skipByFileSeconds:-[self skipFileSecondsForBars:SkipBaseBars() * 4 fallbackWallClockSeconds:kSkipMostSeconds]];
}

- (void)skipByFileSeconds:(NSTimeInterval)fileDelta {
    // When Stopped, at the end of the playlist or after an error, the finished
    // file stays open, so duration alone looks seekable with no node left to
    // seek. Menu validation mirrors this, and the guard here covers the bare
    // keys, which bypass it.
    if (!self.playlistController.currentTrack || self.audioPlayer.isStopped) {
        return;
    }
    NSTimeInterval duration = self.audioPlayer.duration;
    if (duration <= 0) {
        return; // Nothing seekable yet (loading, or no file open).
    }
    NSTimeInterval target = self.audioPlayer.position + fileDelta;
    if (target >= duration) {
        // Past the end, so finish the track as a natural end would. The
        // delegate's didFinishPlaying: advances to the next track, or stops at
        // the end of the playlist.
        [self.audioPlayer finishCurrentTrack];
        return;
    }
    if (target < 0) {
        target = 0; // Skipping before the start seeks to the beginning.
    }
    [self.audioPlayer seekToPosition:target];
}

#pragma mark - Performance effects (bare-key taps/holds; see TransportKeyMonitor)

// The FX menu's toggles. They are written against the pass-throughs below
// rather than against AudioFX directly, so that a menu toggle and a bare-key
// tap are the same flip.

- (IBAction)toggleLowKill:(nullable id)sender {
    self.lowKillActive = !self.lowKillActive;
}

- (IBAction)toggleLowKillBoost:(nullable id)sender {
    self.lowKillBoostActive = !self.lowKillBoostActive;
}

- (IBAction)toggleReverbSend:(nullable id)sender {
    self.reverbSendActive = !self.reverbSendActive;
}

- (IBAction)toggleDelaySend:(nullable id)sender {
    self.delaySendActive = !self.delaySendActive;
}

- (IBAction)toggleShortDelaySend:(nullable id)sender {
    self.shortDelaySendActive = !self.shortDelaySendActive;
}

- (BOOL)lowKillActive {
    return self.audioPlayer.fx.lowKillEnabled;
}

- (void)setLowKillActive:(BOOL)active {
    self.audioPlayer.fx.lowKillEnabled = active;
    [self updateFXIndicators];
}

- (BOOL)lowKillBoostActive {
    return self.audioPlayer.fx.lowKillBoostActive;
}

- (void)setLowKillBoostActive:(BOOL)active {
    self.audioPlayer.fx.lowKillBoostActive = active;
    [self updateFXIndicators];
}

- (BOOL)reverbSendActive {
    return self.audioPlayer.fx.reverbSendEnabled;
}

- (void)setReverbSendActive:(BOOL)active {
    self.audioPlayer.fx.reverbSendEnabled = active;
    [self updateFXIndicators];
}

- (BOOL)delaySendActive {
    return self.audioPlayer.fx.delaySendEnabled;
}

- (void)setDelaySendActive:(BOOL)active {
    self.audioPlayer.fx.delaySendEnabled = active;
    [self updateFXIndicators];
}

- (BOOL)shortDelaySendActive {
    return self.audioPlayer.fx.shortDelaySendEnabled;
}

- (void)setShortDelaySendActive:(BOOL)active {
    self.audioPlayer.fx.shortDelaySendEnabled = active;
    [self updateFXIndicators];
}

// Read back from AudioFX rather than from the caller's intent. The FX object
// enforces its own coupling — clearing lowKillEnabled also clears
// lowKillBoostActive — so only the live flags describe what is actually on.
- (void)updateFXIndicators {
    AudioFX *fx = self.audioPlayer.fx;
    VibeBitPerfectReport report = self.audioPlayer.bitPerfectReport;
    NSInteger bitPerfect = 0;
    if (report.enabled) {
        bitPerfect = (report.status == VibeBitPerfectStatusActive) ? 2 : 1;
    }
    [self.trackDisplay renderFXState:(VibeFXDisplayState){
        .lowKill      = fx.lowKillEnabled,
        .lowKillBoost = fx.lowKillBoostActive,
        .reverb       = fx.reverbSendEnabled,
        .delay        = fx.delaySendEnabled,
        .shortDelay   = fx.shortDelaySendEnabled,
        .bitPerfect   = bitPerfect,
    }];
    [self.trackDisplay renderBitPerfectToolTip:(bitPerfect == 1 ? [self bitPerfectStatusText] : nil)];
}

// One sentence per status, shared by the header's tooltip and the Settings
// caption so the two cannot disagree about why. Every string is English-only
// until release (docs/future/bit-perfect-output.md).
// The rate spelled the way the codec line spells it (AudioTrackMetadata's
// fileInfoLine), so the two never disagree about a unit.
static NSString *VibeSampleRateText(double sampleRate) {
    return [NSString stringWithFormat:STR_LABEL_SAMPLE_RATE,
            [[Formatters sharedInstance] decimalString:sampleRate / 1000 fractionDigits:1]];
}

- (NSString *)bitPerfectStatusText {
    VibeBitPerfectReport report = self.audioPlayer.bitPerfectReport;
    Formatters *formatters = [Formatters sharedInstance];
    switch (report.status) {
        case VibeBitPerfectStatusOff:
            return STR_SETTINGS_BIT_PERFECT_CAPTION_OFF;
        case VibeBitPerfectStatusIdle:
            return STR_SETTINGS_BIT_PERFECT_IDLE;
        case VibeBitPerfectStatusActive: {
            NSString *formatString = report.exclusive ? STR_SETTINGS_BIT_PERFECT_FORMAT_EXCLUSIVE
                    : report.systemDefault ? STR_SETTINGS_BIT_PERFECT_FORMAT_SHARED_DEFAULT
                    : STR_SETTINGS_BIT_PERFECT_FORMAT;
            NSString *format = [NSString stringWithFormat:formatString,
                    VibeSampleRateText(report.sampleRate),
                    [formatters decimalString:report.bitsPerChannel fractionDigits:0]];
            return [NSString stringWithFormat:STR_SETTINGS_BIT_PERFECT_ACTIVE, format];
        }
        case VibeBitPerfectStatusRateUnsupported:
            return [NSString stringWithFormat:STR_SETTINGS_BIT_PERFECT_RATE_UNSUPPORTED,
                    VibeSampleRateText(report.sampleRate)];
        case VibeBitPerfectStatusSwitchFailed:
            return STR_SETTINGS_BIT_PERFECT_SWITCH_FAILED;
        case VibeBitPerfectStatusDepthInsufficient:
            return STR_SETTINGS_BIT_PERFECT_DEPTH;
        case VibeBitPerfectStatusVolumeScaled:
            return [NSString stringWithFormat:STR_SETTINGS_BIT_PERFECT_VOLUME,
                    [formatters decimalString:report.softwareVolume * 100 fractionDigits:0]];
        case VibeBitPerfectStatusExclusiveRefused:
            return STR_SETTINGS_BIT_PERFECT_EXCLUSIVE_REFUSED;
        case VibeBitPerfectStatusSourceLossy:
            return STR_SETTINGS_BIT_PERFECT_LOSSY;
        case VibeBitPerfectStatusFXGraphPresent:
            return [NSString stringWithFormat:STR_SETTINGS_ENABLE_FX_RESTART, VibeAppName()];
    }
    return @"";
}

@end

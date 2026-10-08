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
#import "AudioFX.h"
#import "Formatters.h"
#import "VibeStrings.h"
#import "AudioTrack.h"
#import "PlaylistController.h"
#import "TrackDisplayController.h"
#import "TransportMath.h"

// Without a tempo: fixed wall-clock distances that ignore the bar base.
static const NSTimeInterval kSkipSeconds = 10.0;
static const NSTimeInterval kSkipMoreSeconds = 30.0;
static const NSTimeInterval kSkipMostSeconds = 60.0;

@implementation MainPlayerController (Transport)

static double SkipBaseBars(void) {
    NSInteger base = AppSettings.sharedInstance.skipBaseBars;
    return base > 0 ? (double)base : 8.0;
}

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
    // Stopped leaves the finished file open, so duration alone looks seekable
    // with no voice. Validation mirrors this; the bare keys bypass validation.
    if (!self.playlistController.currentTrack || self.audioPlayer.isStopped) {
        return;
    }
    NSTimeInterval duration = self.audioPlayer.duration;
    if (duration <= 0) {
        return; // Nothing seekable yet (loading, or no file open).
    }
    NSTimeInterval target = self.audioPlayer.position + fileDelta;
    if (target >= duration) {
        // As a natural end would, through didFinishPlaying:.
        [self.audioPlayer finishCurrentTrack];
        return;
    }
    if (target < 0) {
        target = 0; // Skipping before the start seeks to the beginning.
    }
    [self.audioPlayer seekToPosition:target];
}

#pragma mark - Performance effects (bare-key taps/holds; see TransportKeyMonitor)

// Written against the pass-throughs, so a menu toggle and a bare-key tap are
// the same flip.

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

// The live flags, not the caller's intent: AudioFX couples them (clearing
// lowKillEnabled clears lowKillBoostActive).
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
        .shuffle      = AppSettings.sharedInstance.shuffleEnabled,
        .repeatMode   = AppSettings.sharedInstance.repeatMode,
    }];
    [self.trackDisplay renderBitPerfectToolTip:(bitPerfect == 1 ? [self bitPerfectStatusText] : nil)];
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
                    : STR_SETTINGS_BIT_PERFECT_FORMAT;
            NSString *format = [NSString stringWithFormat:formatString,
                    [formatters sampleRateString:report.sampleRate],
                    [formatters decimalString:report.bitsPerChannel fractionDigits:0]];
            return [NSString stringWithFormat:STR_SETTINGS_BIT_PERFECT_ACTIVE, format];
        }
        case VibeBitPerfectStatusRateUnsupported:
            return [NSString stringWithFormat:STR_SETTINGS_BIT_PERFECT_RATE_UNSUPPORTED,
                    [formatters sampleRateString:report.sampleRate]];
        case VibeBitPerfectStatusSwitchFailed:
            return STR_SETTINGS_BIT_PERFECT_SWITCH_FAILED;
        case VibeBitPerfectStatusOutputResampled:
            return STR_SETTINGS_BIT_PERFECT_OUTPUT_RESAMPLED;
        case VibeBitPerfectStatusChannelConversion:
            return STR_SETTINGS_BIT_PERFECT_CHANNELS;
        case VibeBitPerfectStatusDepthInsufficient:
            return STR_SETTINGS_BIT_PERFECT_DEPTH;
        case VibeBitPerfectStatusMuted:
            return STR_SETTINGS_BIT_PERFECT_MUTED;
        case VibeBitPerfectStatusVolumeScaled:
            if (report.balance != 0.5f) {
                return STR_SETTINGS_BIT_PERFECT_BALANCE;
            }
            if (report.softwareVolume < 1.0f) {
                return [NSString stringWithFormat:STR_SETTINGS_BIT_PERFECT_VOLUME,
                        [formatters decimalString:report.softwareVolume * 100 fractionDigits:0]];
            }
            return [NSString stringWithFormat:STR_SETTINGS_BIT_PERFECT_PLAYER_VOLUME,
                    [formatters decimalString:report.playerVolume * 100 fractionDigits:0]];
        case VibeBitPerfectStatusExclusiveRefused:
            return STR_SETTINGS_BIT_PERFECT_EXCLUSIVE_REFUSED;
        case VibeBitPerfectStatusSourceLossy:
            return STR_SETTINGS_BIT_PERFECT_LOSSY;
    }
    return @"";
}

@end

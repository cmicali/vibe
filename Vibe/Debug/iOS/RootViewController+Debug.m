//
//  RootViewController+Debug.m
//  Vibe (iOS)
//
//  See RootViewController+Debug.h. It composes: the model's handles come from
//  PlaybackController (Debug), the chrome and the art window from
//  PlayerViewController (Debug), and the shell's own state — which tab, and
//  whether the card is up — from here.
//
//  The mac twin is Debug/Mac/Introspection/MainPlayerController+DebugPlayerSurface.m.
//

#import "RootViewController+Debug.h"

#if DEBUG

#import "PlaybackController+Debug.h"
#import "PlayerViewController+Debug.h"

#import "AppSettings.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "DebugCommonVerbs.h"
#import "PlaybackController.h"
#import "Playlist.h"

@implementation RootViewController (Debug)

- (NSDictionary *)debugStateDictionary {
    // The player, currentTrack and playlist blocks are the shared ones; the
    // two below are this app's own.
    NSMutableDictionary *state = VibeDebugCommonStateDictionary(self);
    PlaybackController *playback = self.playback;
    NSMutableDictionary *ui = [[self.player debugChromeDictionary] mutableCopy];
    ui[@"screenState"] = @(playback.screenState);
    ui[@"parked"] = @(playback.debugParked);
    ui[@"trackStartPending"] = @(playback.debugTrackStartPending);
    ui[@"error"] = playback.errorText ?: @"";
    // The shell: which tab is up, whether the strip is showing, and whether
    // the card is up over both.
    ui[@"playerPresentation"] = self.isPlayerExpanded ? @"full" : @"minimized";
    ui[@"miniPlayerShown"] = @(self.isMiniPlayerShown);
    ui[@"selectedTab"] = self.selectedTabIdentifier;
    // The library's content-unavailable state stands exactly where the
    // player screen's open hint used to.
    ui[@"libraryEmpty"] = @(playback.playlist.count == 0);
    state[@"ui"] = ui;
    // No analyzeBPM/analyzeKey: BPM and key analysis are macOS-only, so those
    // settings do not exist here. A track's bpm/key still report its tags.
    state[@"settings"] = @{
        @"waveformStyle": Settings.waveformStyle ?: @"",
    };
    return state;
}

- (NSDictionary *)debugArtDictionary {
    return [self.player debugArtDictionary];
}

- (NSDictionary *)debugActionSummary {
    PlaybackController *playback = self.playback;
    return @{
        @"ok": @YES,
        @"state": VibeDebugPlayerStateName(playback.debugPlayer),
        @"index": @(playback.currentIndex),
        @"count": @(playback.playlist.count),
        @"position": @(playback.position),
        @"parked": @(playback.debugParked),
        @"playerPresentation": self.isPlayerExpanded ? @"full" : @"minimized",
    };
}

- (void)debugPlayPause {
    [self.playback playPause];
}

- (void)debugNext {
    [self.playback next];
}

- (void)debugPrevious {
    [self.playback previous];
}

- (void)debugSeekToSeconds:(NSTimeInterval)seconds {
    // The player's duration is 0 while it holds nothing — a parked track — and
    // that is precisely the case worth being able to drive: a scrub there
    // opens the file at the scrubbed position. Falling back to the track's own
    // duration is what the scrubber itself effectively does, since it works in
    // progress rather than seconds.
    NSTimeInterval duration = self.playback.duration;
    if (duration <= 0) {
        duration = self.playback.currentTrack.duration;
    }
    if (duration > 0) {
        [self.player debugSeekToProgress:(float)MAX(0.0, MIN(1.0, seconds / duration))];
    }
}

- (void)debugOpenPath:(NSString *)path {
    [self.playback debugOpenPath:path];
}

- (AudioTrackMetadataCache *)debugMetadataCache {
    return self.playback.debugMetadataCache;
}

- (AudioWaveformCache *)debugWaveformCache {
    return [self.player debugWaveformCache];
}

#pragma mark - What the shared invariant checks read

- (AudioPlayer *)debugPlayer {
    return self.playback.debugPlayer;
}

- (NSUInteger)debugPlaylistCount {
    return self.playback.playlist.count;
}

- (NSUInteger)debugPlaylistCurrentIndex {
    return self.playback.currentIndex;
}

- (AudioTrack *)debugPlaylistCurrentTrack {
    return self.playback.currentTrack;
}

- (AudioTrack *)debugPlaylistTrackAtIndex:(NSUInteger)index {
    return [self.playback.playlist trackAtIndex:index];
}

- (AudioTrack *)debugDisplayedTrack {
    return self.playback.displayedTrack;
}

- (BOOL)debugIsLoading {
    return self.playback.screenState == VibePlayerScreenStateLoading;
}

// No pitch control on iOS, so the varispeed never leaves 1.0 — the same
// constant the Now Playing publish sends.
- (double)debugPlaybackRate {
    return 1.0;
}

@end

#endif

//
//  PlaybackController+Debug.m
//  Vibe (iOS)
//
//  See PlaybackController+Debug.h.
//

#import "PlaybackController+Debug.h"

#if DEBUG

#import "PlaybackControllerInternal.h"

@implementation PlaybackController (Debug)

- (AudioPlayer *)debugPlayer {
    return _player;
}

- (AudioTrackMetadataCache *)debugMetadataCache {
    return _metadataCache;
}

- (BOOL)debugParked {
    return _parked;
}

- (BOOL)debugTrackStartPending {
    return _trackStartPending;
}

- (void)debugOpenPath:(NSString *)path {
    [_folderSession openExternalURL:[NSURL fileURLWithPath:path] openInPlace:YES];
}

@end

#endif

//
//  AudioTrackMetadata+ArtLoad.m
//  Vibe
//

#import "AudioTrackMetadata+ArtLoad.h"

@implementation AudioTrackMetadata (ArtLoad)

- (void)dispatchArtLoadIfNeededStillWanted:(BOOL (^)(void))stillWanted
                                completion:(void (^)(VibeImage *_Nullable))completion {
    if (!self.artNeedsLoad || self.artLoadDispatched) {
        return;
    }
    self.artLoadDispatched = YES;
    // Cache-hit metadata does not carry the art bytes, and extracting them
    // re-reads the audio file, which can block on a cloud placeholder until it
    // downloads. User-initiated, not utility: this load gates the header, the
    // Now Playing card and — on macOS — the dock tile all at once, and the
    // user is looking at the screen waiting on it.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
        VibeImage *loaded = [self loadArtBlocking];  // may block; background thread
        // "Did anything actually load?" is otherwise unanswerable from outside:
        // a track that shows no art has either found none or is still reading
        // one, and on a cloud file that read is a download. Same reasoning as
        // FolderArtResolver's readArtAtPath: logging every load.
        LogInfo(@"Art load: %@ for '%@' in %.1fs", loaded ? @"image" : @"nothing",
                self.title ?: @"?", CFAbsoluteTimeGetCurrent() - startedAt);
        dispatch_async(dispatch_get_main_queue(), ^{
            // Cleared first, unconditionally: artNeedsLoad is what decides
            // whether anything is left to do, and a caller that died mid-load
            // must not leave the metadata looking permanently in flight.
            self.artLoadDispatched = NO;
            if (!stillWanted()) {
                [self discardDecodedArt];
                return;
            }
            completion(loaded);
        });
    });
}

@end

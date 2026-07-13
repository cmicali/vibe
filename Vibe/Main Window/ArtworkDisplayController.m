//
//  ArtworkDisplayController.m
//  Vibe
//

#import "ArtworkDisplayController.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "ArtworkImageView.h"
#import "BackgroundArtworkImageView.h"
#import "NSDockTile+Util.h"

@implementation ArtworkDisplayController {
    ArtworkImageView            *_artworkView;
    BackgroundArtworkImageView  *_backgroundView;
    __weak NSImage              *_displayedArt;
    // Track whose full-res art is currently held decoded (weak: if the
    // playlist was replaced the track deallocates and takes its art with it).
    __weak AudioTrack           *_artOwnerTrack;
    BOOL                        _initialized;
}

- (instancetype)initWithArtworkView:(ArtworkImageView *)artworkView
                     backgroundView:(BackgroundArtworkImageView *)backgroundView {
    self = [super init];
    if (self) {
        _artworkView = artworkView;
        _backgroundView = backgroundView;
    }
    return self;
}

// Artwork display policy: new art replaces old art directly. While the new
// track's art is still unresolved (metadata pending, load worth dispatching,
// or a load in flight), the PREVIOUS track's art stays on screen — no flash
// of the default between tracks. The default backdrop is installed only when
// the track is known to be artless.
- (void)updateForTrack:(AudioTrack *)track {
    if (track.albumArt) {
        if (_displayedArt != track.albumArt) {
            _artworkView.image = track.albumArt;
            [_backgroundView setArtworkImage:track.albumArt];
            [NSDockTile setDockIcon:track.albumArt];
            _displayedArt = track.albumArt;
        }
        _initialized = YES;
        return;
    }

    AudioTrackMetadata *metadata = track.metadata;
    // albumArtLoadDispatched is cleared when a load completes, so here it
    // means exactly "a load is in flight".
    BOOL artUnresolved = !metadata || metadata.albumArtNeedsLoad || metadata.albumArtLoadDispatched;
    if (!artUnresolved || !_initialized) {
        [self showDefaultArtwork];
    }
    _initialized = YES;

    // Cache-hit metadata doesn't carry the art bytes; extracting them
    // re-reads the audio file, which can block on a cloud placeholder
    // until it downloads. Do it off the main thread and refresh when done.
    if (metadata.albumArtNeedsLoad && !metadata.albumArtLoadDispatched) {
        metadata.albumArtLoadDispatched = YES;
        __weak ArtworkDisplayController *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSImage *loaded = metadata.albumArt; // may block; background thread
            dispatch_async(dispatch_get_main_queue(), ^{
                // Resolved either way — clear the in-flight marker. No
                // duplicate-dispatch risk: albumArtNeedsLoad is NO after any
                // completion (image decoded, or attempted and artless).
                metadata.albumArtLoadDispatched = NO;
                ArtworkDisplayController *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                AudioTrack *currentTrack = strongSelf.currentTrackProvider
                        ? strongSelf.currentTrackProvider() : nil;
                if (currentTrack != track) {
                    return;
                }
                if (loaded) {
                    if (strongSelf.artDidResolveHandler) {
                        strongSelf.artDidResolveHandler();
                    }
                }
                else {
                    // Definitively artless: only now does the default
                    // replace the previous track's art.
                    [strongSelf showDefaultArtwork];
                }
            });
        });
    }
}

// Installs the record-bg default backdrop (no-op if it's already showing).
- (void)showDefaultArtwork {
    if (!_displayedArt && _initialized) {
        return;
    }
    _artworkView.image = [NSImage imageNamed:@"record-bg"];
    [_backgroundView setArtworkImage:[NSImage imageNamed:@"record-bg"]];
    [NSDockTile resetToAppIcon];
    _displayedArt = nil;
}

- (void)trackDidStartPlaying:(AudioTrack *)track {
    // Demote the previous track's full-res art (decoded bitmap + compressed
    // bytes, ~4-9MB together). Without this, every track played in a session
    // stays pinned for the playlist's lifetime. The thumbnail is kept; the art
    // reloads on demand if the track becomes current again.
    if (_artOwnerTrack && _artOwnerTrack != track) {
        [_artOwnerTrack.metadata discardDecodedAlbumArt];
    }
    _artOwnerTrack = track;
}

@end

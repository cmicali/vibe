//
//  ArtworkDisplayController.m
//  Vibe
//

#import "ArtworkDisplayController.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "ArtworkImageView.h"
#import "NSDockTile+Util.h"
#import "NSImage+Util.h"

// The raw dominant color can be anything from neon to near-black; pulling
// saturation/brightness into this band keeps the tint recognizable as the
// art's color without overpowering the glass or silhouetting the labels.
static const CGFloat kTintAlpha         = 0.4;
static const CGFloat kTintMaxBrightness = 0.8;
static const CGFloat kTintMinBrightness = 0.5;
static const CGFloat kTintMaxSaturation = 0.75;
// The tint drops to half strength while the window isn't key, like the
// system dims inactive-window chrome.
static const CGFloat kTintInactiveFactor = 0.5;

@implementation ArtworkDisplayController {
    ArtworkImageView            *_artworkView;
    NSView                      *_headerTintView;
    NSColor                     *_headerTintColor; // full-strength; applied halved when inactive
    __weak NSImage              *_displayedArt;
    // Track whose full-res art is currently held decoded (weak: if the
    // playlist was replaced the track deallocates and takes its art with it).
    __weak AudioTrack           *_artOwnerTrack;
    BOOL                        _initialized;
}

- (instancetype)initWithArtworkView:(ArtworkImageView *)artworkView
                     headerTintView:(NSView *)headerTintView {
    self = [super init];
    if (self) {
        _artworkView = artworkView;
        _headerTintView = headerTintView;
        // Object nil (filtered in the handler): the tint view isn't
        // necessarily in a window yet at construction time.
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(windowKeyStateChanged:)
                       name:NSWindowDidBecomeKeyNotification object:nil];
        [center addObserver:self selector:@selector(windowKeyStateChanged:)
                       name:NSWindowDidResignKeyNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)windowKeyStateChanged:(NSNotification *)note {
    if (note.object == _headerTintView.window) {
        [self applyCurrentHeaderTint];
    }
}

// Pushes the stored tint to the header wash, at half strength while the
// window isn't key.
- (void)applyCurrentHeaderTint {
    NSColor *color = _headerTintColor;
    if (color && !_headerTintView.window.isKeyWindow) {
        color = [color colorWithAlphaComponent:color.alphaComponent * kTintInactiveFactor];
    }
    _headerTintView.layer.backgroundColor = color.CGColor; // nil color clears
}

// Tints the header glass to the art's dominant color (nil art → untinted).
- (void)applyHeaderTintFromArt:(NSImage *)art {
    NSColor *color = [art dominantColor];
    if (color) {
        CGFloat hue, saturation, brightness;
        [color getHue:&hue saturation:&saturation brightness:&brightness alpha:NULL];
        color = [NSColor colorWithHue:hue
                           saturation:MIN(saturation, kTintMaxSaturation)
                           brightness:MAX(kTintMinBrightness, MIN(brightness, kTintMaxBrightness))
                                alpha:kTintAlpha];
    }
    _headerTintColor = color;
    [self applyCurrentHeaderTint];
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
            [self applyHeaderTintFromArt:track.albumArt];
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

// Installs the record-bg default art and clears the glass tint (no-op if
// already showing).
- (void)showDefaultArtwork {
    if (!_displayedArt && _initialized) {
        return;
    }
    _artworkView.image = [NSImage imageNamed:@"record-bg"];
    _headerTintColor = nil;
    [self applyCurrentHeaderTint];
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

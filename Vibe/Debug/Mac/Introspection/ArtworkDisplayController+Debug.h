//
//  ArtworkDisplayController+Debug.h
//  Vibe
//
//  Declaration-only inspection of the main header's live artwork state. The
//  implementation stays with ArtworkDisplayController, and the shipping
//  header remains limited to rendering actions.
//

#if DEBUG

#import "ArtworkDisplayController.h"

@class AudioTrack;
@class AudioTrackMetadata;

NS_ASSUME_NONNULL_BEGIN

@interface ArtworkDisplayController (Debug)

@property (weak, readonly, nullable) AudioTrack *debugArtworkTargetTrack;
@property (weak, readonly, nullable) AudioTrackMetadata *debugArtworkTargetMetadata;
@property (weak, readonly, nullable) NSImage *debugArtworkTargetArt;
@property (weak, readonly, nullable) AudioTrack *debugInstalledArtworkOwnerTrack;
@property (weak, readonly, nullable) AudioTrackMetadata *debugInstalledArtworkMetadata;
@property (weak, readonly, nullable) NSImage *debugInstalledArtworkSource;
@property (nonatomic, readonly) BOOL debugShowingDefaultArtwork;
@property (nonatomic, readonly) BOOL debugArtworkRenderPending;

@end

NS_ASSUME_NONNULL_END

#endif

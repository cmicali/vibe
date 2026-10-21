//
//  AudioTrackInternal.h
//  Vibe
//
//  Metadata-loader installation and identity-bound delivery edges.
//

#import "AudioTrack.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrack (Internal)

// Installs metadata only while this row still has no successful answer. The
// decision and store share the track monitor, so a caller may publish exactly
// when this returns YES without racing another successful installation.
- (BOOL)installMetadataIfUnresolved:(AudioTrackMetadata *)metadata;

// Runs delivery only while metadata is still this row's exact installed
// object, and keeps that identity stable through the call. The block runs
// under the track's recursive monitor: it may re-enter track accessors, but
// must not wait for a worker that installs metadata on this track.
- (BOOL)deliverIfMetadataStillInstalled:(AudioTrackMetadata *)metadata
                              usingBlock:(NS_NOESCAPE dispatch_block_t)delivery;

@end

NS_ASSUME_NONNULL_END

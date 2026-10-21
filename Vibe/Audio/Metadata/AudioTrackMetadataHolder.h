//
//  AudioTrackMetadataHolder.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "VibePlayableItem.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioTrackMetadata;

// An item the metadata loader installs its results into. It extends the
// playable item, because the loader reads the same item's file and cache key.
// The holder keeps the check and the store under one monitor of its own, so a
// replaced item never shows a stale result.
@protocol AudioTrackMetadataHolder <VibePlayableItem>

// nil until a loader installs one. Atomic: loader workers install it while
// main reads it.
@property (atomic, strong, nullable, readonly) AudioTrackMetadata *metadata;

// Installs metadata only while the holder has no successful answer
// (parsedOK) read from the same version (the metadata's cacheKey). So a new
// version's answer replaces the old version's. The decision and the store
// share the holder's monitor, so a caller may publish exactly when this
// returns YES without racing another successful installation.
- (BOOL)installMetadataIfUnresolved:(AudioTrackMetadata *)metadata;

// Runs delivery only while metadata is still the holder's exact installed
// object, and keeps that identity stable through the call. The block runs
// under the same monitor, which must be recursive: it may re-enter the
// holder's accessors, but must not wait for a worker that installs metadata
// on this holder.
- (BOOL)deliverIfMetadataStillInstalled:(AudioTrackMetadata *)metadata
                             usingBlock:(NS_NOESCAPE dispatch_block_t)delivery;

@end

NS_ASSUME_NONNULL_END

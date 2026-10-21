//
//  AudioTrackMetadata.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AudioFileFormat.h"
#import "PlatformTypes.h"
#import "MusicalKey.h"

NS_ASSUME_NONNULL_BEGIN

// Posted on main after an evicted embedded thumbnail has been decoded again.
// The object is the AudioTrackMetadata whose cachedThumbnail is now non-nil.
FOUNDATION_EXPORT NSNotificationName const AudioTrackMetadataThumbnailDidLoadNotification;

@interface AudioTrackMetadata : NSObject <NSSecureCoding, NSCopying>

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Any field can be absent from the file or the cache entry. A failed parse
// keeps the filename title and any facts read before the failure.
@property (copy, nullable, readonly) NSString *title;
@property (copy, nullable, readonly) NSString *artist;
@property (copy, nullable, readonly) VibeAudioFileFormat fileType;
@property (copy, nullable, readonly) NSNumber *bitrate;
@property (copy, nullable, readonly) NSNumber *sampleRate;
@property (assign, readonly) NSTimeInterval duration;
// FLAC, ALAC, AIFF, WAV, W64 or CAF. A lossless bitrate is implied by the
// rate and depth, so the codec line leaves it out.
@property (readonly, getter=isLossless) BOOL lossless;

// The tagged tempo (ID3 TBPM, MP4 tmpo, Vorbis/FLAC BPM); 0 when untagged.
@property (assign, readonly) float bpm;

// The tagged key (ID3 TKEY, Vorbis/FLAC INITIALKEY, the MP4 initialkey atom).
// VibeMusicalKeyNone when untagged or unparseable; every init path must set
// it, since the zero default is C major.
@property (assign, readonly) VibeMusicalKey key;

// YES after a completed TagLib or CoreAudio parse. Never cache a NO instance:
// its fallback or partial facts would shadow real tags until the key changes.
@property (readonly) BOOL parsedOK;

// Non-blocking: already-decoded art or nil, never a decode.
- (nullable VibeImage *)cachedArt;

// YES when full art still needs background work (a read or a decode).
- (BOOL)artNeedsLoad;

// For a track no longer shown at full size: drops the decoded image and the
// source bytes, keeps the thumbnail bytes, cancels parked work and re-arms the
// load. Without it every played track pins its decoded art. Main thread only.
- (void)discardDecodedArt;

// Tells unresolved work from artlessness. Main thread.
@property (nonatomic, readonly, getter=isArtLoadPending) BOOL artLoadPending;

// Admits one bounded full-art load when needed. stillWanted is checked on main
// at each cancellation edge; completion runs on main only for a current,
// still-wanted request.
- (void)loadArtIfNeededStillWanted:(BOOL (^)(void))stillWanted
                        completion:(void (^)(VibeImage *_Nullable art))completion;

// The 128px row thumbnail; safe while drawing. On a miss with compact bytes
// it admits one bounded off-main decode, returns nil, and posts
// AudioTrackMetadataThumbnailDidLoadNotification when the pixels land. Only
// the file's own thumbnail is archived, never a folder cover.
- (nullable VibeImage *)cachedThumbnail;

@end

NS_ASSUME_NONNULL_END

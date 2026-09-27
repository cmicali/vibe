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

// All nullable: a failed parse sets only the filename-derived title, and any
// field can be absent from the file or the cache entry.
@property (copy, nullable, readonly) NSString *title;
@property (copy, nullable, readonly) NSString *artist;
@property (copy, nullable, readonly) VibeAudioFileFormat fileType;
@property (copy, nullable, readonly) NSNumber *bitrate;
@property (copy, nullable, readonly) NSNumber *sampleRate;
@property (assign, readonly) NSTimeInterval duration;

// The tagged tempo (ID3 TBPM, MP4 tmpo, Vorbis/FLAC BPM); 0 when untagged.
@property (assign, readonly) float bpm;

// The tagged key (ID3 TKEY, Vorbis/FLAC INITIALKEY, the MP4 initialkey atom).
// VibeMusicalKeyNone when untagged or unparseable; every init path must set
// it, since the zero default is C major.
@property (assign, readonly) VibeMusicalKey key;

// YES only when TagLib opened the file. A NO instance carries only the
// filename title and must never be cached, or it shadows the real tags until
// the cache key changes.
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

// The codec line both screens render: file type, bitrate (lossy only) and
// sample rate, joined with " | ", each only when present (a zero rate is
// stored as nil); empty with no fileType. Main thread only (Formatters).
- (NSString *)fileInfoLine;

@end

NS_ASSUME_NONNULL_END

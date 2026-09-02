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

// All nullable. A failed parse populates only the filename-derived title, a
// tagless file carries no artist, audioProperties can be absent, leaving no
// bitrate or sample rate, and a validated cache decode can hand back nil for
// any field, since initWithCoder: treats them all as optional.
@property (copy, nullable, readonly) NSString *title;
@property (copy, nullable, readonly) NSString *artist;
@property (copy, nullable, readonly) VibeAudioFileFormat fileType;
@property (copy, nullable, readonly) NSNumber *bitrate;
@property (copy, nullable, readonly) NSNumber *sampleRate;
@property (assign, readonly) NSTimeInterval duration;

// The producer-tagged tempo, from ID3 TBPM, MP4 tmpo or Vorbis and FLAC BPM,
// and 0 when the file carries none. A tagged value beats the decode-pass
// analysis in AudioTrack.detectedBPM, because DJs curate their tags.
@property (assign, readonly) float bpm;

// The producer-tagged musical key, parsed from ID3 TKEY, Vorbis and FLAC
// INITIALKEY, or the MP4 initialkey freeform atom, in any of the notations
// VibeMusicalKeyFromString reads. VibeMusicalKeyNone (-1) when the file
// carries none or the tag is unparseable — the ivar default of 0 would read
// as C major, so every init path must set it. A tagged value beats the
// decode-pass analysis in AudioTrack.detectedKey, like bpm.
@property (assign, readonly) VibeMusicalKey key;

// YES only when TagLib actually opened the file and read its tag. NO means the
// parse failed, on a dataless cloud placeholder or a transient I/O error, and
// only the filename-derived title is populated. Such an instance must never be
// persisted to the cache, or the empty entry shadows the real tags until the
// cache key changes.
@property (readonly) BOOL parsedOK;

// Non-blocking: it returns the art only if it has already been decoded, and
// never does decode work, since a full-resolution ImageIO decode is a 10-100ms
// hitch on the main thread.
- (nullable VibeImage *)cachedArt;

// YES when producing full-resolution art still needs background work: a file
// read, which may block, or a decode of in-memory art bytes.
- (BOOL)artNeedsLoad;

// Demotes a track no longer displayed at full resolution. It drops both the
// decoded full-size image and the source bytes, keeps compact thumbnail bytes,
// and re-arms the on-demand load so the art returns if the track becomes current
// again. Without it, every track played in a session pins about 4MB of decoded
// art for the playlist's lifetime. It also cancels parked work and detaches an
// active materialization waiter. Main thread only.
- (void)discardDecodedArt;

// Whether this metadata object's one asynchronous full-art request is admitted.
// Main-thread callers use it to distinguish unresolved work from artlessness.
@property (nonatomic, readonly, getter=isArtLoadPending) BOOL artLoadPending;

// Admits one bounded asynchronous full-art load when needed. The source file
// first joins central metadata-priority materialization; blocking reads and
// decodes run off main. stillWanted is checked on main at each cancellation
// edge, and completion runs on main only for a current, still-wanted request.
- (void)loadArtIfNeededStillWanted:(BOOL (^)(void))stillWanted
                        completion:(void (^)(VibeImage *_Nullable art))completion;

// A downscaled copy of the full art, suited to small table cells. This accessor
// only reads already-decoded pixels and is safe while drawing. If compact
// embedded bytes survived a shared-cache eviction, it admits one bounded
// off-main decode and returns nil; AudioTrackMetadataThumbnailDidLoadNotification
// asks visible callers to redraw when those pixels arrive. **The file's own
// thumbnail — never a folder cover — is what gets serialized to the on-disk
// cache**, so recovery never reopens the song.
- (nullable VibeImage *)cachedThumbnail;

// The codec line both screens render: file type, bitrate (lossy only), sample
// rate, joined with " | ". Each part is appended only when present — TagLib can
// return no audioProperties even with a fileType set, and a rate it reports as
// 0 is stored as nil — so it never reads "(null) kbps", "0 kbps" or "0.0 kHz",
// and it is the empty string with no fileType at all.| ". Each part is appended only when present — TagLib can
// return no audioProperties even with a fileType set — so it never reads
// "(null) kbps" or "0.0 kHz", and it is the empty string with no fileType at
// all. Whether to SHOW it is the caller's decision; how it reads is here, so
// the two screens cannot drift.
//
// MAIN THREAD ONLY: it goes through Formatters.
- (NSString *)fileInfoLine;

@end

NS_ASSUME_NONNULL_END

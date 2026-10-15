// AudioTrack's metadata, duck-typed (Tests/AGENTS.md). AudioTrack only sends
// it messages and never names the class, so a fake cast to the property type
// behaves identically and keeps TagLib out. VibeTests and VibeiOSTests share it.

#import <Foundation/Foundation.h>

#import "PlatformImage.h"

NS_ASSUME_NONNULL_BEGIN

@interface FakeTrackMetadata : NSObject
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic) float bpm;
// -1 at init, as the real metadata: 0 is C major.
@property (nonatomic) NSInteger key;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, strong, nullable) VibeImage *cachedArt;
@property (nonatomic, strong, nullable) VibeImage *cachedThumbnail;
// installMetadataIfUnresolved: consults it.
@property (nonatomic) BOOL parsedOK;
@property (nonatomic, copy) NSString *fileInfoLine;
@property (nonatomic) BOOL artNeedsLoad;
@property (nonatomic, getter=isArtLoadPending) BOOL artLoadPending;
// What the last loadArtIfNeededStillWanted:completion: was handed.
@property (nonatomic, copy, nullable) BOOL (^artStillWanted)(void);
@property (nonatomic, copy, nullable) void (^artCompletion)(VibeImage *_Nullable);
// discardDecodedArt counts here and drops cachedArt.
@property (nonatomic) NSUInteger discardedArtCount;
@end

NS_ASSUME_NONNULL_END

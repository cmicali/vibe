//
//  MetadataLoaderTestFakes.h
//
//  The fakes the AudioTrackMetadataLoader tests run the real loader over:
//  the holder, the duck-typed metadata, the loader's owner and delegate, and
//  a provider operation each test completes by hand.
//

#import <XCTest/XCTest.h>

#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataLoader.h"
#import "MetadataParseCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

// The tests' own holder: a file, its window, and the metadata a loader
// installs. It memoizes its cache key as an app's row may, stamped with
// NSURL.cacheKeyGeneration. A fresh object per call, so two holders for one
// file stay two holders.
@interface VibeLoaderTestTrack : NSObject <AudioTrackMetadataHolder>
+ (VibeLoaderTestTrack *)withURL:(NSURL *)url;
// A window of the file in CD frames; an end of 0 runs to the file's end.
- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)cueStart cueEnd:(NSUInteger)cueEnd
        NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface VibeLoaderTestMetadata : NSObject <NSCopying>
@property(nonatomic) BOOL parsedOK;
@property(nonatomic, copy) NSString *marker;
// The loader stamps the version it read.
@property(atomic, copy, nullable) NSString *cacheKey;
@end

AudioTrackMetadata *VibeLoaderTestMetadataResult(BOOL parsedOK, NSString *marker);

// A cue image's rows: consecutive ten-second windows of one file.
NSMutableArray<VibeLoaderTestTrack *> *VibeLoaderTestCueRows(NSURL *image, NSUInteger count);

@interface VibeMetadataLoaderOwner : NSObject
@property(nonatomic, strong) MetadataParseCoordinator<VibeLoaderTestTrack *> *parseCoordinator;
@property(atomic) uint64_t cacheGeneration;
@property(atomic, strong, nullable) id metadataCache;
@end

@interface VibeMetadataLoaderDelegate : NSObject <AudioTrackMetadataCacheDelegate>
@property(nonatomic, strong, nullable) XCTestExpectation *deliveryExpectation;
@property(nonatomic, strong) NSMutableArray<VibeLoaderTestTrack *> *deliveredTracks;
@property(nonatomic, strong) NSMutableArray<AudioTrackMetadata *> *deliveredMetadata;
@property(nonatomic) BOOL allDeliveriesOnMain;
@end

@class VibeMetadataLoaderOperationController;

@interface VibeMetadataLoaderOperation : NSObject <AudioFileMaterializationOperation>
- (instancetype)initWithURL:(NSURL *)url
                       role:(VibeAudioFileMaterializationRole)role
                 controller:(VibeMetadataLoaderOperationController *)controller;
- (void)completeReady;
- (void)completeFailed;
- (void)forceCancel;
@end

@interface VibeMetadataLoaderOperationController : NSObject
@property(atomic) BOOL blocksUntilCancelled;
@property(atomic, strong, nullable) XCTestExpectation *firstStartExpectation;
@property(atomic, strong, nullable) XCTestExpectation *allStartsExpectation;
@property(atomic, strong, nullable) XCTestExpectation *cancellationExpectation;
@property(atomic, copy, nullable) void (^startObserver)(NSURL *url,
        VibeAudioFileMaterializationRole role);
- (void)setAfterFailureCheck:(nullable dispatch_block_t)afterFailureCheck;
- (nullable dispatch_block_t)takeAfterFailureCheck;
- (id<AudioFileMaterializationOperation>)operationForURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role;
- (void)recordStartForURL:(NSURL *)url role:(VibeAudioFileMaterializationRole)role;
- (void)recordCancellation;
- (BOOL)consumeFailureForURL:(NSURL *)url;
- (NSArray<NSURL *> *)startedURLs;
- (NSArray<NSNumber *> *)startedRoles;
- (void)failNextStarts:(NSUInteger)count forURL:(NSURL *)url;
- (void)completeFirstReady;
- (void)completeFirstFailed;
- (void)completeLastReady;
- (void)cancelAll;
@end

NS_ASSUME_NONNULL_END

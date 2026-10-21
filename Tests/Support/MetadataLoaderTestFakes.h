//
//  MetadataLoaderTestFakes.h
//
//  The fakes the AudioTrackMetadataLoader tests run the real loader over:
//  the duck-typed metadata, the loader's owner and delegate, and a provider
//  operation each test completes by hand. MetadataLoaderTestFakes.m also
//  holds the suite's one AudioTrackMetadata decoy.
//

#import <XCTest/XCTest.h>

#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataLoader.h"
#import "MetadataParseCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface VibeLoaderTestMetadata : NSObject <NSCopying>
@property(nonatomic) BOOL parsedOK;
@property(nonatomic, copy) NSString *marker;
// The loader stamps the version it read.
@property(atomic, copy, nullable) NSString *cacheKey;
@end

AudioTrackMetadata *VibeLoaderTestMetadataResult(BOOL parsedOK, NSString *marker);

// A cue image's rows: consecutive ten-second windows of one file.
NSMutableArray<AudioTrack *> *VibeLoaderTestCueRows(NSURL *image, NSUInteger count);

@interface VibeMetadataLoaderOwner : NSObject
@property(nonatomic, strong) MetadataParseCoordinator<AudioTrack *> *parseCoordinator;
@property(atomic) uint64_t cacheGeneration;
@property(atomic, strong, nullable) id metadataCache;
@end

@interface VibeMetadataLoaderDelegate : NSObject <AudioTrackMetadataCacheDelegate>
@property(nonatomic, strong, nullable) XCTestExpectation *deliveryExpectation;
@property(nonatomic, strong) NSMutableArray<AudioTrack *> *deliveredTracks;
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

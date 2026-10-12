//
//  AudioTrackMetadataLoaderTestCase.h
//
//  The harness the AudioTrackMetadataLoader tests share: a real loader over
//  a real coordinator, a per-test temp root, and a teardown that waits for
//  both coordinators to settle. It runs no tests. Each topic is a subclass
//  in its own AudioTrackMetadataLoader<Topic>Tests.m beside it.
//

#import <XCTest/XCTest.h>

#import "AudioTrackMetadataLoader+Debug.h"
#import "MetadataLoaderTestFakes.h"
#import "PlaceholderFiles+Debug.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataLoaderTestCase : XCTestCase {
@protected
    VibeMetadataLoaderOwner *_owner;
    NSMutableArray<AudioTrackMetadataLoader *> *_loaders;
    NSMutableArray<VibeMetadataLoaderOperationController *> *_controllers;
    NSMutableArray<AudioFileMaterializationCoordinator *> *_coordinators;
    NSMutableArray<VibeMetadataLoaderDelegate *> *_delegates;
    NSMutableSet<NSString *> *_localNames;
    NSURL *_testRootURL;
}
- (NSURL *)URLNamed:(NSString *)name;
- (AudioTrack *)trackNamed:(NSString *)name;
- (AudioLoadingConfiguration *)testConfigurationWithValues:(VibeAudioLoadingConfigurationValues)values;
- (AudioLoadingConfiguration *)testConfigurationWithRetryCount:(NSUInteger)retryCount;
- (AudioLoadingConfiguration *)testConfiguration;
- (AudioTrackMetadataLoader *)loaderWithController:
        (VibeMetadataLoaderOperationController *)controller
        cacheReader:(nullable VibeAudioTrackMetadataCacheReader)cacheReader
        fileParser:(nullable VibeAudioTrackMetadataFileParser)fileParser;
- (AudioTrackMetadataLoader *)loaderWithController:
        (VibeMetadataLoaderOperationController *)controller
        configuration:(AudioLoadingConfiguration *)configuration
        cacheReader:(nullable VibeAudioTrackMetadataCacheReader)cacheReader
        fileParser:(nullable VibeAudioTrackMetadataFileParser)fileParser;
- (AudioTrackMetadataLoader *)loaderWithController:
        (VibeMetadataLoaderOperationController *)controller
        configuration:(AudioLoadingConfiguration *)configuration
        delegate:(nullable VibeMetadataLoaderDelegate *)delegate
        cacheReader:(nullable VibeAudioTrackMetadataCacheReader)cacheReader
        fileParser:(nullable VibeAudioTrackMetadataFileParser)fileParser;
- (void)markLocal:(NSURL *)url;
- (void)waitForCondition:(BOOL (^)(void))condition
             description:(NSString *)description;
- (void)waitForDelay:(NSTimeInterval)delay;
@end

NS_ASSUME_NONNULL_END

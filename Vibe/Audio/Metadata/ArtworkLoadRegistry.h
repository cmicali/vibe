//
//  ArtworkLoadRegistry.h
//  Vibe
//
//  Admission for AudioTrackArtwork's async art loads, its only client: across
//  all rows at most two run and five pend; a request past that is dropped
//  before it marks the row pending, and the next redraw re-requests it (J6).
//  A file boundary, not a second owner.
//

#import <Foundation/Foundation.h>
#import "AudioTrackArtworkInternal.h" // the class the hook category extends
#import "PlatformTypes.h"

@class AudioFileMaterializationCoordinator;
@class AudioWorkScheduler;

NS_ASSUME_NONNULL_BEGIN

static const NSUInteger kArtworkLoadMaximumRunningCount = 2;
static const NSUInteger kArtworkLoadMaximumPendingCount = 5;
static const NSUInteger kArtworkLoadMaximumActiveCount =
        kArtworkLoadMaximumRunningCount + kArtworkLoadMaximumPendingCount;
static const NSTimeInterval kArtworkLoadPendingGrace = 30;

// Main thread only.
@interface ArtworkLoadRegistry : NSObject
- (instancetype)initWithMaterializationCoordinator:
        (AudioFileMaterializationCoordinator *)materializationCoordinator
                                      workScheduler:(AudioWorkScheduler *)workScheduler;
- (void)loadArtwork:(AudioTrackArtwork *)artwork
               label:(nullable NSString *)label
         stillWanted:(BOOL (^)(void))stillWanted
           completion:(void (^)(VibeImage * _Nullable image))completion;
- (void)cancelLoadsForArtwork:(AudioTrackArtwork *)artwork;
@property (nonatomic, readonly) NSUInteger registeredRequestCount;
@end

// Implemented in AudioTrackArtwork.m.
@interface AudioTrackArtwork (ArtworkLoadRegistrySupport)
- (BOOL)prepareAsyncLoadReturningGeneration:(NSUInteger *)generation
                                  sourceURL:(NSURL * _Nullable * _Nonnull)sourceURL;
- (BOOL)isGenerationCurrent:(NSUInteger)generation;
- (void)clearLoadPendingForGeneration:(NSUInteger)generation;
- (void)invalidateDecodedArtForGeneration:(NSUInteger)generation;
@end

NS_ASSUME_NONNULL_END

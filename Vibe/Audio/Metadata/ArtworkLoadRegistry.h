//
//  ArtworkLoadRegistry.h
//  Vibe
//
//  The bounded-admission state machine behind AudioTrackArtwork's async art
//  loads: across all rows, at most two reads or decodes run, five sit
//  scheduler-pending, and a seven-artwork desired window waits beyond that.
//  Private to AudioTrackArtwork — it is the registry's only client, reached
//  through loadArtIfNeededWithLabel:stillWanted:completion:. A file boundary,
//  not a second coordinator: the flow's owner is still AudioTrackArtwork.
//

#import <Foundation/Foundation.h>
#import "AudioTrackArtworkInternal.h" // the class the hook category extends
#import "PlatformTypes.h"

@class AudioFileMaterializationCoordinator;
@class AudioWorkScheduler;

NS_ASSUME_NONNULL_BEGIN

// The global bound. Running and pending name the work scheduler's dimensions;
// active is their sum, the registry's own registration cap.
static const NSUInteger kArtworkLoadMaximumRunningCount = 2;
static const NSUInteger kArtworkLoadMaximumPendingCount = 5;
static const NSUInteger kArtworkLoadMaximumActiveCount =
        kArtworkLoadMaximumRunningCount + kArtworkLoadMaximumPendingCount;
static const NSUInteger kArtworkLoadMaximumWaitingCount = 7;
static const NSTimeInterval kArtworkLoadPendingGrace = 30;

// Main-thread only, like the display request path that drives it.
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

// The per-row hooks the registry drives, implemented in AudioTrackArtwork.m,
// whose class extension declares the same four for its own implementation.
@interface AudioTrackArtwork (ArtworkLoadRegistrySupport)
- (BOOL)prepareAsyncLoadReturningGeneration:(NSUInteger *)generation
                                  sourceURL:(NSURL * _Nullable * _Nonnull)sourceURL;
- (BOOL)isGenerationCurrent:(NSUInteger)generation;
- (void)clearLoadPendingForGeneration:(NSUInteger)generation;
- (void)invalidateDecodedArtForGeneration:(NSUInteger)generation;
@end

NS_ASSUME_NONNULL_END

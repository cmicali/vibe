// The in-simulator bundle's harness and fakes. Runs no tests.

#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>

#import "EqualizerLevelSource.h"
#import "FakeTrackMetadata.h"
#import "TestFilesystemGuard.h"
#import "OutputRouteRules.h"
#import "PlayerScreenRules.h"

@class AudioTrack;
@class PlaybackController;
@class VibePlaylist<__covariant ObjectType>;

NS_ASSUME_NONNULL_BEGIN

// PlaybackController, duck-typed, so no second AudioPlayer joins the host's
// one. The screens read the properties below. Any other selector
// PlaybackController declares is recorded in calls and answers zero.
@interface FakePlayback : NSObject <EqualizerLevelSource>
@property (nonatomic, strong) VibePlaylist<AudioTrack *> *playlist;
@property (nonatomic) VibePlayerScreenState screenState;
@property (nonatomic, strong, nullable) AudioTrack *displayedTrack;
@property (nonatomic, copy, nullable) NSString *errorText;
@property (nonatomic) BOOL isPlaying;
@property (nonatomic) BOOL audioOutputActive;
@property (nonatomic) NSTimeInterval position;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) BOOL seekInFlight;
@property (nonatomic) float pendingSeekProgress;
@property (nonatomic) BOOL currentOpenSlow;
@property (nonatomic) BOOL bufferingNoticeShown;
@property (nonatomic) VibeOutputRouteKind outputRouteKind;
@property (nonatomic, copy, nullable) NSString *outputRouteName;
@property (nonatomic, readonly) NSArray<NSString *> *calls;
// The balance of equalizerLevelsWanted: calls.
@property (nonatomic, readonly) NSInteger levelConsumers;

// Typed for the screens' initializers.
- (PlaybackController *)asPlayback;
- (nullable AudioTrack *)currentTrack;
- (NSUInteger)currentIndex;
// Sends a one-argument PlaybackObserver selector, with self, to every observer
// that answers it.
- (void)notify:(SEL)selector;
- (void)clearCalls;
@end

// Balanced demand, counted.
@interface CountingLevelSource : NSObject <EqualizerLevelSource>
@property (nonatomic, readonly) NSInteger consumers;
@property (nonatomic, readonly) NSInteger wantedCalls;
@end

@interface IOSSimTestCase : XCTestCase

// A window of its own on the host's scene, fresh for each test.
@property (nonatomic, readonly) UIWindow *window;

// A track whose file need not exist. A nil title and artist leave the
// filename-derived single line.
- (AudioTrack *)trackNamed:(NSString *)name
                     title:(nullable NSString *)title
                    artist:(nullable NSString *)artist
                  duration:(NSTimeInterval)duration;

// Spins main until the condition holds, up to VIBE_TEST_HANG_TIMEOUT.
- (BOOL)eventually:(BOOL (^)(void))condition;

@end

// Every UILabel under view, depth first.
FOUNDATION_EXTERN NSArray<UILabel *> *VibeLabelsIn(UIView *view);
// The first visible label under view showing exactly text.
FOUNDATION_EXTERN UILabel *_Nullable VibeLabelWithText(UIView *view, NSString *text);

NS_ASSUME_NONNULL_END

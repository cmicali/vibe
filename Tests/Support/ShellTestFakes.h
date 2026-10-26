//
//  ShellTestFakes.h
//
//  The mac shell's collaborators at the boundary the host-less suite controls.
//  MainPlayerController is built through its injected constructor with these
//  in place of the audio player, the metadata scan and the window. The player
//  and the scan are duck-typed and cast to the property types, as
//  AudioTrackMetadata's fake is. A selector that a newly tested path sends
//  and the fake lacks fails loudly.
//

#import <AppKit/AppKit.h>

#import "AudioPlayer+BitPerfect.h"
#import "MainPlayerControllerInternal.h"

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibeShellTestPlayerState) {
    VibeShellTestPlayerStateStopped,
    VibeShellTestPlayerStatePlaying,
    VibeShellTestPlayerStatePaused,
};

// The transport calls the shell makes, in call order, naming each track by
// its file's stem: "play a", "park a", "stop", "prefetch b", "prefetch nil".
@interface VibeShellTestPlayer : NSObject
@property (nonatomic) VibeShellTestPlayerState state;
@property (nonatomic) BOOL outputAudioActive;
@property (nonatomic) BOOL levelsEnabled;
@property (nonatomic) VibeBitPerfectReport bitPerfectReport;
@property (nonatomic) float maxPitch;
@property (nonatomic, strong, readonly) NSMutableArray<NSString *> *calls;
// The last prefetchTrack: argument, kept as the exact object.
@property (nonatomic, strong, nullable, readonly) AudioTrack *parkedTrack;
@property (nonatomic, readonly) NSUInteger prefetchCount;
@end

// The metadata scan's calls the shell makes: "load 3", "cancel",
// "abandon a", "now a". The neighborhood is kept, not logged.
@interface VibeShellTestMetadataCache : NSObject
@property (nonatomic, strong, readonly) NSMutableArray<NSString *> *calls;
@property (nonatomic, copy, readonly) NSArray<AudioTrack *> *neighborhood;
@end

// The window at the boundary +Window reads: the OS's occlusion, and the pitch
// panel's shown flag, which MainWindow answers in the app. Borderless and
// deferred, so it never shows. Its content view is layer-backed, as
// MainWindow's is.
@interface VibeShellTestWindow : NSWindow
@property (nonatomic) BOOL occluded;
+ (instancetype)windowWithSize:(NSSize)size;
- (BOOL)isPitchPanelShown;
@end

NS_ASSUME_NONNULL_END

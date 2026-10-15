//
//  ShellTestFakes.m
//

#import "ShellTestFakes.h"

#import "AudioPlayer.h"
#import "AudioPlayer+BitPerfect.h"
#import "AudioTrack.h"
#import "MainMenuBuilder.h"
#import "PlaylistTestSupport.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
// PlaylistController's row menu is the one part of MainMenuBuilder it uses.
@implementation MainMenuBuilder
+ (NSMenuItem *)symbolItemWithTitle:(NSString *)title
                         symbolName:(NSString *)symbolName
                             action:(SEL)action
                             target:(id)target
                         identifier:(NSString *)identifier {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = target;
    item.identifier = identifier;
    return item;
}
@end
#pragma clang diagnostic pop

static NSString *NameOf(AudioTrack *_Nullable track) {
    return track ? NamesOf(@[track]) : @"nil";
}

@implementation VibeShellTestPlayer {
    AudioTrack *_currentTrack;
}

- (instancetype)init {
    if ((self = [super init])) {
        _calls = [NSMutableArray array];
    }
    return self;
}

- (void)play:(AudioTrack *)track {
    [_calls addObject:[@"play " stringByAppendingString:NameOf(track)]];
    _currentTrack = track;
    _state = VibeShellTestPlayerStatePlaying;
}

- (void)play:(AudioTrack *)track atPosition:(NSTimeInterval)position startPaused:(BOOL)startPaused {
    [_calls addObject:[(startPaused ? @"park " : @"play ") stringByAppendingString:NameOf(track)]];
    _currentTrack = track;
    _state = startPaused ? VibeShellTestPlayerStatePaused : VibeShellTestPlayerStatePlaying;
}

- (void)stop {
    [_calls addObject:@"stop"];
    _currentTrack = nil;
    _state = VibeShellTestPlayerStateStopped;
}

- (void)prefetchTrack:(AudioTrack *)track {
    [_calls addObject:[@"prefetch " stringByAppendingString:NameOf(track)]];
    _parkedTrack = track;
    _prefetchCount++;
}

- (BOOL)getPlaybackIntent:(VibePendingPlaybackIntent *)intent forTrack:(AudioTrack *)track {
    if (_state == VibeShellTestPlayerStateStopped) {
        return NO;
    }
    *intent = VibePendingPlaybackIntentMake(0, _state == VibeShellTestPlayerStatePaused);
    return YES;
}

- (BOOL)isStopped {
    return _state == VibeShellTestPlayerStateStopped;
}

- (BOOL)isPlaying {
    return _state == VibeShellTestPlayerStatePlaying;
}

- (BOOL)isPaused {
    return _state == VibeShellTestPlayerStatePaused;
}

- (BOOL)isLoading {
    return NO;
}

- (BOOL)isBuffering {
    return NO;
}

- (BOOL)bufferingNoticeShown {
    return NO;
}

- (AudioTrack *)currentTrack {
    return _currentTrack;
}

- (NSTimeInterval)position {
    return 0;
}

- (NSTimeInterval)duration {
    return 0;
}

- (float)pitch {
    return 0;
}

- (AudioFX *)fx {
    return nil;
}

- (VibeBitPerfectReport)bitPerfectReport {
    return (VibeBitPerfectReport){0};
}

- (void)noteDisplayedPosition:(NSTimeInterval)position forTrack:(AudioTrack *)track {
}

- (BOOL)copyBandLevels:(float *)out count:(NSUInteger)count sequence:(uint64_t *)sequence {
    return NO;
}

@end

@implementation VibeShellTestMetadataCache

- (instancetype)init {
    if ((self = [super init])) {
        _calls = [NSMutableArray array];
        _neighborhood = @[];
    }
    return self;
}

- (void)loadMetadata:(NSArray<AudioTrack *> *)tracks {
    [_calls addObject:[NSString stringWithFormat:@"load %lu", (unsigned long)tracks.count]];
}

- (void)cancelScan {
    [_calls addObject:@"cancel"];
}

- (void)loadMetadataNow:(AudioTrack *)track {
    [_calls addObject:[@"now " stringByAppendingString:NameOf(track)]];
}

- (void)abandonQueuedTrack:(AudioTrack *)track {
    [_calls addObject:[@"abandon " stringByAppendingString:NameOf(track)]];
}

- (void)setNeighborhoodTracks:(NSArray<AudioTrack *> *)tracks {
    _neighborhood = [tracks copy];
}

@end

static BOOL gTestWindowVisible = YES;

@implementation MainPlayerController (ShellTestWindow)

+ (BOOL)testWindowVisible {
    return gTestWindowVisible;
}

+ (void)setTestWindowVisible:(BOOL)visible {
    gTestWindowVisible = visible;
}

- (BOOL)isWindowVisible {
    return gTestWindowVisible;
}

@end

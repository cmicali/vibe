#import "IOSSimTestCase.h"

#import "AudioTrackInternal.h"
#import "PlaybackController.h"
#import "Playlist.h"

@implementation FakePlayback {
    NSHashTable *_observers;
    NSMutableArray<NSString *> *_calls;
    NSInteger _levelConsumers;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _playlist = [[Playlist alloc] init];
        _observers = [NSHashTable weakObjectsHashTable];
        _calls = [NSMutableArray array];
    }
    return self;
}

- (PlaybackController *)asPlayback {
    return (PlaybackController *)self;
}

- (AudioTrack *)currentTrack {
    return _playlist.currentTrack;
}

- (NSUInteger)currentIndex {
    return _playlist.currentIndex;
}

- (void)addObserver:(id)observer {
    [_observers addObject:observer];
}

- (void)removeObserver:(id)observer {
    [_observers removeObject:observer];
}

- (void)notify:(SEL)selector {
    for (id observer in _observers.allObjects) {
        if ([observer respondsToSelector:selector]) {
            ((void (*)(id, SEL, id))[observer methodForSelector:selector])(observer, selector, self);
        }
    }
}

- (NSArray<NSString *> *)calls {
    return [_calls copy];
}

- (void)clearCalls {
    [_calls removeAllObjects];
}

- (NSInteger)levelConsumers {
    return _levelConsumers;
}

- (BOOL)copyEqualizerLevels:(float *)outLevels count:(NSUInteger)count sequence:(uint64_t *)outSequence {
    return NO;
}

- (void)equalizerLevelsWanted:(BOOL)wanted {
    _levelConsumers += wanted ? 1 : -1;
}

// Only PlaybackController's own selectors are answered, so a typo or a
// removed method still fails loudly.
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [super methodSignatureForSelector:selector]
            ?: [PlaybackController instanceMethodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [_calls addObject:NSStringFromSelector(invocation.selector)];
    NSUInteger length = invocation.methodSignature.methodReturnLength;
    if (length > 0) {
        void *zero = calloc(1, length);
        [invocation setReturnValue:zero];
        free(zero);
    }
}

@end

@implementation CountingLevelSource

- (BOOL)copyEqualizerLevels:(float *)outLevels count:(NSUInteger)count sequence:(uint64_t *)outSequence {
    return NO;
}

- (void)equalizerLevelsWanted:(BOOL)wanted {
    _wantedCalls++;
    _consumers += wanted ? 1 : -1;
}

@end

@implementation IOSSimTestCase {
    NSDictionary<NSString *, id> *_savedDefaults;
}

// The host's settings are the in-memory store TestFilesystemGuard installs,
// which the whole process shares, so each test leaves it as it found it.
static NSString *DefaultsDomain(void) {
    return NSBundle.mainBundle.bundleIdentifier;
}

- (void)setUp {
    [super setUp];
    _savedDefaults = [NSUserDefaults.standardUserDefaults persistentDomainForName:DefaultsDomain()] ?: @{};
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class]) {
            scene = (UIWindowScene *)candidate;
        }
    }
    XCTAssertNotNil(scene, @"the host app has no window scene");
    _window = [[UIWindow alloc] initWithWindowScene:scene];
    _window.frame = scene.effectiveGeometry.coordinateSpace.bounds;
    _window.hidden = NO;
}

- (void)tearDown {
    _window.rootViewController = nil;
    _window.hidden = YES;
    _window = nil;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *now = [defaults persistentDomainForName:DefaultsDomain()] ?: @{};
    for (NSString *key in now) {
        if (!_savedDefaults[key]) {
            [defaults removeObjectForKey:key];
        }
    }
    [_savedDefaults enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (![now[key] isEqual:value]) {
            [defaults setObject:value forKey:key];
        }
    }];
    [super tearDown];
}

- (AudioTrack *)trackNamed:(NSString *)name
                     title:(NSString *)title
                    artist:(NSString *)artist
                  duration:(NSTimeInterval)duration {
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    AudioTrack *track = [[AudioTrack alloc] initWithURL:url];
    FakeTrackMetadata *metadata = [[FakeTrackMetadata alloc] init];
    metadata.title = title;
    metadata.artist = artist;
    metadata.duration = duration;
    metadata.parsedOK = YES;
    XCTAssertTrue([track installMetadataIfUnresolved:(AudioTrackMetadata *)metadata]);
    return track;
}

- (BOOL)eventually:(BOOL (^)(void))condition {
    return VibeSpinUntil(condition);
}

@end

static void CollectLabels(UIView *view, NSMutableArray<UILabel *> *labels) {
    if ([view isKindOfClass:UILabel.class]) {
        [labels addObject:(UILabel *)view];
    }
    for (UIView *subview in view.subviews) {
        CollectLabels(subview, labels);
    }
}

NSArray<UILabel *> *VibeLabelsIn(UIView *view) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    CollectLabels(view, labels);
    return labels;
}

UILabel *VibeLabelWithText(UIView *view, NSString *text) {
    for (UILabel *label in VibeLabelsIn(view)) {
        if (!label.hidden && [label.text isEqualToString:text]) {
            return label;
        }
    }
    return nil;
}

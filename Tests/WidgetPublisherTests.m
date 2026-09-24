//
//  WidgetPublisherTests.m
//  VibeTests
//
//  The publisher's lifecycle against its real queue and container writes, in
//  the per-run container TestFilesystemGuard redirects it to. No WidgetKit:
//  the reloader bundle is absent from the test host, so reloads and queries
//  are no-ops unless WidgetTestReloader stands in, holding every query for
//  the test to answer in the order under test. The demand signal is the real
//  Darwin notification, under the redirected container's own name.
//

#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "NSURL+Hash.h"
#import "VibeWidgetState.h"
#import "WidgetPublisherInternal.h"

// WidgetKit, as the tests' own: every query is held until a test answers it,
// in whatever order the test chooses.
@interface WidgetTestReloader : NSObject <VibeWidgetReloading>
@end

static NSMutableArray<void (^)(BOOL, NSError *)> *gHeldQueries;
static NSUInteger gQueriesAsked;
static NSUInteger gMostQueriesOut;

@implementation WidgetTestReloader

+ (void)reload {
}

+ (void)queryPlaced:(void (^)(BOOL, NSError *))completion {
    @synchronized (self) {
        [gHeldQueries addObject:completion];
        gQueriesAsked++;
        gMostQueriesOut = MAX(gMostQueriesOut, gHeldQueries.count);
    }
}

+ (NSUInteger)queriesOut {
    @synchronized (self) {
        return gHeldQueries.count;
    }
}

// Answers the oldest query still out.
+ (void)answerPlaced:(BOOL)placed error:(NSError *)error {
    void (^completion)(BOOL, NSError *);
    @synchronized (self) {
        completion = gHeldQueries.firstObject;
        [gHeldQueries removeObjectAtIndex:0];
    }
    completion(placed, error);
}

@end

@interface WidgetPublisherTests : XCTestCase
@end

@implementation WidgetPublisherTests

- (void)setUp {
    // A Mac that never had a widget: no snapshot, no mark.
    NSURL *container = VibeWidgetState.containerURL;
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:container
            includingPropertiesForKeys:nil options:0 error:NULL];
    for (NSURL *url in contents) {
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    }
    gHeldQueries = [NSMutableArray array];
    gQueriesAsked = 0;
    gMostQueriesOut = 0;
}

- (void)tearDown {
    [WidgetPublisher setReloaderClass:nil];
}

static AudioTrack *WidgetTestTrack(NSString *name) {
    return [[AudioTrack alloc] initWithURL:[NSURL fileURLWithPath:
            [@"/tmp/vibe-widget-tests" stringByAppendingPathComponent:name]]];
}

static void Drain(WidgetPublisher *publisher) {
    dispatch_sync(publisher.queue, ^{});
}

// Every hop settled: the queue, then main, then the queue again, since an
// answer goes queue → main and a coalesced question main → queue.
static void Settle(WidgetPublisher *publisher) {
    for (int pass = 0; pass < 4; pass++) {
        Drain(publisher);
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

// A placed widget rendering, through the real Darwin signal (under the tests'
// own name), given the time notifyd takes to deliver it.
static void WidgetRenders(WidgetPublisher *publisher) {
    [VibeWidgetState noteWidgetDemand];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    Settle(publisher);
}

static BOOL SnapshotNamesTrack(AudioTrack *track) {
    VibeWidgetState *state = [VibeWidgetState loadState];
    return state.hasTrack && [state.trackKey isEqualToString:[track.url pathKey]];
}

// A publisher answering to the tests' WidgetKit whose admissions hand over
// whatever `publishCurrent` publishes, as a shell hands over its playback as
// it is by then.
static WidgetPublisher *ShellPublisherPublishing(void (^publishCurrent)(WidgetPublisher *publisher)) {
    [WidgetPublisher setReloaderClass:WidgetTestReloader.class];
    WidgetPublisher *publisher = [[WidgetPublisher alloc] init];
    __weak WidgetPublisher *weakPublisher = publisher;
    publisher.activationHandler = ^{
        publishCurrent(weakPublisher);
    };
    return publisher;
}

// The same, playing whatever `current` answers from the top.
static WidgetPublisher *ShellPublisher(AudioTrack *(^current)(void)) {
    return ShellPublisherPublishing(^(WidgetPublisher *publisher) {
        [publisher updateWithTrack:current() position:0 duration:100 playing:YES startPending:NO];
    });
}

// A publisher whose gate is open, publishing `track` as playing from the shell
// the way activation asks for it.
static WidgetPublisher *ActivePublisher(AudioTrack *track) {
    WidgetPublisher *publisher = [[WidgetPublisher alloc] init];
    __weak WidgetPublisher *weakPublisher = publisher;
    __weak AudioTrack *weakTrack = track;
    publisher.activationHandler = ^{
        [weakPublisher updateWithTrack:weakTrack position:10 duration:100
                               playing:YES startPending:NO];
    };
    [publisher setWidgetPlaced:YES];
    Drain(publisher);
    return publisher;
}

- (void)testAPublisherWithNoWidgetKeepsAndWritesNothingItIsHanded {
    WidgetPublisher *publisher = [[WidgetPublisher alloc] init];
    __weak AudioTrack *weakTrack = nil;
    __weak id weakWaveform = nil;
    @autoreleasepool {
        AudioTrack *track = WidgetTestTrack(@"inactive.wav");
        // Never baked here, so any object stands in for the envelope.
        CodableAudioWaveform *waveform = (CodableAudioWaveform *)[NSObject new];
        weakTrack = track;
        weakWaveform = waveform;
        [publisher updateWithTrack:track position:10 duration:100 playing:YES startPending:NO];
        [publisher offerWaveform:waveform forTrack:track];
        [publisher settingsDidChange];
        [publisher updateWithTrack:nil position:0 duration:0 playing:NO startPending:NO];
    }
    Drain(publisher);
    XCTAssertNil(weakTrack, @"the publisher kept the track it was handed with no widget placed");
    XCTAssertNil(weakWaveform, @"the publisher kept the envelope it was offered with no widget placed");
    XCTAssertNil([VibeWidgetState loadState], @"a snapshot was written with no widget placed");
    [publisher publishEmptyForTermination];
    XCTAssertNil([VibeWidgetState loadState], @"quitting with no widget placed wrote a snapshot");
}

- (void)testActivationPublishesWhatTheShellSaysIsTrueNow {
    AudioTrack *track = WidgetTestTrack(@"activation.wav");
    WidgetPublisher *publisher = [[WidgetPublisher alloc] init];
    __block NSUInteger activations = 0;
    __weak WidgetPublisher *weakPublisher = publisher;
    publisher.activationHandler = ^{
        activations++;
        [weakPublisher updateWithTrack:track position:10 duration:100
                               playing:YES startPending:NO];
    };
    [publisher updateWithTrack:track position:5 duration:100 playing:YES startPending:NO];
    XCTAssertEqual(activations, 0u);
    [publisher setWidgetPlaced:YES];
    [publisher setWidgetPlaced:YES];
    Drain(publisher);
    XCTAssertEqual(activations, 1u, @"opening an open gate must not ask the shell again");
    VibeWidgetState *state = [VibeWidgetState loadState];
    XCTAssertTrue(state.hasTrack);
    XCTAssertTrue(state.playing);
    XCTAssertEqualWithAccuracy(state.position, 10, 0.001, @"the shell's current position, not an earlier tick's");
    XCTAssertEqualObjects(state.trackKey, [track.url pathKey]);
}

- (void)testTheLastWidgetGoingLeavesTheEmptySnapshotAndLetsGoOfTheTrack {
    __weak AudioTrack *weakTrack = nil;
    WidgetPublisher *publisher = nil;
    @autoreleasepool {
        AudioTrack *track = WidgetTestTrack(@"removed.wav");
        weakTrack = track;
        publisher = ActivePublisher(track);
        XCTAssertTrue([VibeWidgetState loadState].hasTrack);
        [publisher setWidgetPlaced:NO];
    }
    Drain(publisher);
    XCTAssertFalse([VibeWidgetState loadState].hasTrack,
                   @"the snapshot still claims a track, which a widget added while the app is closed would draw");
    XCTAssertNil(weakTrack, @"the publisher still holds the track after the last widget went");
}

- (void)testQuittingRightAfterTheLastWidgetGoesWaitsForTheEmptySnapshot {
    AudioTrack *track = WidgetTestTrack(@"quit.wav");
    WidgetPublisher *publisher = ActivePublisher(track);
    XCTAssertTrue([VibeWidgetState loadState].hasTrack);
    // A slow write ahead of the clear, released from elsewhere: the quit below
    // blocks main until the queue reaches the clear behind it.
    dispatch_semaphore_t slowWrite = dispatch_semaphore_create(0);
    dispatch_async(publisher.queue, ^{
        dispatch_semaphore_wait(slowWrite, DISPATCH_TIME_FOREVER);
    });
    [publisher setWidgetPlaced:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_semaphore_signal(slowWrite);
    });
    [publisher publishEmptyForTermination];
    XCTAssertFalse([VibeWidgetState loadState].hasTrack,
                   @"quit returned before the empty snapshot landed");
}

#pragma mark - Placement answers, in the order they arrive

- (void)testAStaleNoneCannotShutTheGateUnderAWidgetPlacedAfterItWasAsked {
    // A widget rendered once, so launch asks; the answer is held while a
    // widget is placed and renders.
    [VibeWidgetState markWidgetMayBePlaced];
    __block AudioTrack *current = nil;
    WidgetPublisher *publisher = ShellPublisher(^{ return current; });
    Settle(publisher);
    XCTAssertEqual(WidgetTestReloader.queriesOut, 1u);
    WidgetRenders(publisher);
    XCTAssertTrue(publisher.widgetPlaced);
    // The launch question's "none", asked before that widget existed.
    [WidgetTestReloader answerPlaced:NO error:nil];
    Settle(publisher);
    XCTAssertTrue(publisher.widgetPlaced, @"a stale none shut the gate under a placed widget");
    XCTAssertTrue(VibeWidgetState.widgetMayBePlaced, @"a stale none deleted the mark");
    current = WidgetTestTrack(@"after-stale-none.wav");
    [publisher updateWithTrack:current position:0 duration:100 playing:YES startPending:NO];
    Settle(publisher);
    [WidgetTestReloader answerPlaced:YES error:nil];
    Settle(publisher);
    XCTAssertTrue(SnapshotNamesTrack(current), @"playback after a stale none is not published");
}

- (void)testOneQueryAtATimeSoAnOlderYesCannotLandAfterANewerNone {
    __block AudioTrack *current = WidgetTestTrack(@"coalesced.wav");
    WidgetPublisher *publisher = ShellPublisher(^{ return current; });
    [publisher setWidgetPlaced:YES];
    Settle(publisher);
    [publisher refreshPlaced];
    [publisher refreshPlaced];
    Settle(publisher);
    XCTAssertEqual(WidgetTestReloader.queriesOut, 1u, @"a second question raced the first");
    [WidgetTestReloader answerPlaced:YES error:nil];
    Settle(publisher);
    XCTAssertEqual(WidgetTestReloader.queriesOut, 1u, @"the request made meanwhile was not asked after");
    [WidgetTestReloader answerPlaced:NO error:nil];
    Settle(publisher);
    XCTAssertFalse(publisher.widgetPlaced);
    XCTAssertFalse([VibeWidgetState loadState].hasTrack);
    XCTAssertEqual(gMostQueriesOut, 1u);
}

- (void)testAFailedQueryIsNoAnswerAndTheNextForegroundAsksAgain {
    [VibeWidgetState markWidgetMayBePlaced];
    __block AudioTrack *current = WidgetTestTrack(@"failed.wav");
    WidgetPublisher *publisher = ShellPublisher(^{ return current; });
    Settle(publisher);
    [WidgetTestReloader answerPlaced:NO error:[NSError errorWithDomain:@"test" code:1 userInfo:nil]];
    Settle(publisher);
    XCTAssertFalse(publisher.widgetPlaced, @"a failure turned publishing on");
    XCTAssertTrue(VibeWidgetState.widgetMayBePlaced, @"a failure deleted the mark");
    [publisher refreshPlaced];
    Settle(publisher);
    XCTAssertEqual(WidgetTestReloader.queriesOut, 1u, @"the foreground after a failure did not ask again");
    [WidgetTestReloader answerPlaced:YES error:nil];
    Settle(publisher);
    XCTAssertTrue(publisher.widgetPlaced);
    XCTAssertTrue(SnapshotNamesTrack(current));
}

#pragma mark - A widget removed while the app stays in the background

- (void)testATrackChangeAfterTheWidgetWentSilentAsksBeforeItsWork {
    __block AudioTrack *current = WidgetTestTrack(@"silent-a.wav");
    WidgetPublisher *publisher = ShellPublisher(^{ return current; });
    [publisher setWidgetPlaced:YES];
    Drain(publisher);
    XCTAssertTrue(SnapshotNamesTrack(current));
    AudioTrack *first = current;
    // The widget was removed; nothing renders; the next track comes.
    current = WidgetTestTrack(@"silent-b.wav");
    [publisher updateWithTrack:current position:0 duration:100 playing:YES startPending:NO];
    [publisher settingsDidChange];
    [publisher updateWithTrack:current position:3 duration:100 playing:YES startPending:NO];
    Settle(publisher);
    XCTAssertEqual(WidgetTestReloader.queriesOut, 1u, @"the silent widget was not asked about");
    XCTAssertTrue(SnapshotNamesTrack(first), @"the next track was published before the answer");
    [WidgetTestReloader answerPlaced:NO error:nil];
    Settle(publisher);
    XCTAssertFalse(publisher.widgetPlaced);
    XCTAssertFalse([VibeWidgetState loadState].hasTrack, @"the removed widget's snapshot still claims a track");
    // Nothing after the answer asks or writes.
    current = WidgetTestTrack(@"silent-c.wav");
    [publisher updateWithTrack:current position:0 duration:100 playing:YES startPending:NO];
    [publisher settingsDidChange];
    Settle(publisher);
    XCTAssertEqual(gQueriesAsked, 1u);
    XCTAssertFalse([VibeWidgetState loadState].hasTrack);
}

- (void)testAHeldTrackChangePublishesTheCurrentTrackWhenTheWidgetIsStillThere {
    __block AudioTrack *current = WidgetTestTrack(@"held-a.wav");
    WidgetPublisher *publisher = ShellPublisher(^{ return current; });
    [publisher setWidgetPlaced:YES];
    Drain(publisher);
    current = WidgetTestTrack(@"held-b.wav");
    [publisher updateWithTrack:current position:0 duration:100 playing:YES startPending:NO];
    Settle(publisher);
    current = WidgetTestTrack(@"held-c.wav");
    [WidgetTestReloader answerPlaced:YES error:nil];
    Settle(publisher);
    XCTAssertTrue(SnapshotNamesTrack(current), @"the answer published a track the shell had moved past");
    XCTAssertEqual(gQueriesAsked, 1u, @"publishing what the answer admitted asked again");
}

- (void)testAWidgetThatRenderedGrantsNothingToTheNextTrack {
    __block AudioTrack *current = WidgetTestTrack(@"acknowledged-a.wav");
    WidgetPublisher *publisher = ShellPublisher(^{ return current; });
    [publisher setWidgetPlaced:YES];
    Drain(publisher);
    AudioTrack *first = current;
    // The widget draws A, then is removed; B comes, strip and all.
    WidgetRenders(publisher);
    current = WidgetTestTrack(@"acknowledged-b.wav");
    CodableAudioWaveform *waveform = (CodableAudioWaveform *)[NSObject new];
    [publisher updateWithTrack:current position:0 duration:100 playing:YES startPending:NO];
    [publisher offerWaveform:waveform forTrack:current];
    Settle(publisher);
    XCTAssertEqual(WidgetTestReloader.queriesOut, 1u, @"A's render was taken as leave to publish B");
    XCTAssertTrue(SnapshotNamesTrack(first), @"B was written before the answer");
    [WidgetTestReloader answerPlaced:NO error:nil];
    Settle(publisher);
    XCTAssertFalse(publisher.widgetPlaced);
    XCTAssertFalse([VibeWidgetState loadState].hasTrack);
    XCTAssertEqual(gQueriesAsked, 1u);
}

- (void)testSameTrackChangesAskFirstAndJoinOneQuestion {
    AudioTrack *track = WidgetTestTrack(@"same-track.wav");
    __block BOOL playing = YES;
    __block NSTimeInterval position = 0;
    WidgetPublisher *publisher = ShellPublisherPublishing(^(WidgetPublisher *p) {
        [p updateWithTrack:track position:position duration:100 playing:playing startPending:NO];
    });
    [publisher setWidgetPlaced:YES];
    Drain(publisher);
    WidgetRenders(publisher);
    NSDate *publishedAt = [VibeWidgetState loadState].positionDate;
    // Removed; then Control Center pauses, seeks and resumes, the app still
    // in the background.
    playing = NO;
    [publisher updateWithTrack:track position:position duration:100 playing:playing startPending:NO];
    position = 50;
    [publisher updateWithTrack:track position:position duration:100 playing:playing startPending:NO];
    playing = YES;
    [publisher updateWithTrack:track position:position duration:100 playing:playing startPending:NO];
    Settle(publisher);
    XCTAssertEqual(gQueriesAsked, 1u, @"same-track changes were not asked about, or not as one question");
    XCTAssertEqualObjects([VibeWidgetState loadState].positionDate, publishedAt,
                          @"a same-track change was written before the answer");
    [WidgetTestReloader answerPlaced:YES error:nil];
    Settle(publisher);
    VibeWidgetState *state = [VibeWidgetState loadState];
    XCTAssertEqualWithAccuracy(state.position, 50, 0.001, @"the answer did not publish the state as of then");
    XCTAssertTrue(state.playing);
    XCTAssertEqual(gQueriesAsked, 1u, @"publishing what the answer admitted asked again");
    // An unchanged tick has nothing to write, so nothing to ask.
    [publisher updateWithTrack:track position:position duration:100 playing:playing startPending:NO];
    Settle(publisher);
    XCTAssertEqual(gQueriesAsked, 1u);
}

- (void)testAStripForTheSameTrackWaitsForTheAnswer {
    __block AudioTrack *current = WidgetTestTrack(@"strip.wav");
    WidgetPublisher *publisher = ShellPublisher(^{ return current; });
    [publisher setWidgetPlaced:YES];
    Drain(publisher);
    WidgetRenders(publisher);
    // Removed; the envelope for the track on screen lands afterwards.
    CodableAudioWaveform *waveform = (CodableAudioWaveform *)[NSObject new];
    [publisher offerWaveform:waveform forTrack:current];
    [publisher settingsDidChange];
    Settle(publisher);
    XCTAssertEqual(gQueriesAsked, 1u, @"the strip was not asked about");
    NSURL *strip = [[VibeWidgetState loadState] waveformURLPlayed:YES light:NO];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:strip.path],
                   @"the strip was baked before the answer");
    [WidgetTestReloader answerPlaced:NO error:nil];
    Settle(publisher);
    XCTAssertFalse(publisher.widgetPlaced);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:strip.path]);
}

- (void)testReadingTheSnapshotSignalsNoWidget {
    AudioTrack *track = WidgetTestTrack(@"read.wav");
    [ActivePublisher(track) publishEmptyForTermination];
    XCTAssertNotNil([VibeWidgetState loadState]);
    XCTAssertFalse(VibeWidgetState.widgetMayBePlaced,
                   @"a read marked the container: the gallery's previews read with nothing placed");
}

@end

//
//  WidgetPublisherTests.m
//  VibeTests
//
//  The publisher's lifecycle against its real queue and container writes, in
//  the per-run container TestFilesystemGuard redirects it to. No WidgetKit:
//  the reloader bundle is absent from the test host, so reloads and queries
//  are no-ops, and the gate is moved the way its two sources move it.
//

#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "NSURL+Hash.h"
#import "VibeWidgetState.h"
#import "WidgetPublisherInternal.h"

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
}

static AudioTrack *WidgetTestTrack(NSString *name) {
    return [[AudioTrack alloc] initWithURL:[NSURL fileURLWithPath:
            [@"/tmp/vibe-widget-tests" stringByAppendingPathComponent:name]]];
}

static void Drain(WidgetPublisher *publisher) {
    dispatch_sync(publisher.queue, ^{});
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

- (void)testReadingTheSnapshotSignalsNoWidget {
    AudioTrack *track = WidgetTestTrack(@"read.wav");
    [ActivePublisher(track) publishEmptyForTermination];
    XCTAssertNotNil([VibeWidgetState loadState]);
    XCTAssertFalse(VibeWidgetState.widgetMayBePlaced,
                   @"a read marked the container: the gallery's previews read with nothing placed");
}

@end

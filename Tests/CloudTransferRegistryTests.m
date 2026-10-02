//
//  CloudTransferRegistryTests.m
//  VibeTests
//
//  The registry with an injected monitor factory, through its Internal.h seam.
//

#import <XCTest/XCTest.h>

#import "AudioFileOpenRules.h"
#import "CloudTransferRegistryInternal.h"

@interface VibeTestTransferMonitor : NSObject <VibeCloudTransferMonitor>
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) void (^handler)(float fraction);
@property (nonatomic, copy) void (^movement)(void);
@property (nonatomic) NSUInteger cancelCount;
@end

@implementation VibeTestTransferMonitor
- (void)cancel {
    self.cancelCount++;
}
@end

// A second observer, as each shell's player model is beside its row list.
@interface VibeTestTransferObserver : NSObject <CloudTransferRegistryObserver>
@property (nonatomic) NSUInteger changes;
@property (nonatomic, strong) NSMutableArray<NSURL *> *moves;
@end

@implementation VibeTestTransferObserver
- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry {
    self.changes++;
}
- (void)cloudTransferRegistry:(CloudTransferRegistry *)registry didMoveTransferForURL:(NSURL *)url {
    [self.moves addObject:url];
}
@end

@interface CloudTransferRegistryTests : XCTestCase <CloudTransferRegistryObserver>
@end

@implementation CloudTransferRegistryTests {
    CloudTransferRegistry *_registry;
    NSMutableArray<VibeTestTransferMonitor *> *_monitors;
    NSUInteger _observerCallbacks;
}

- (void)setUp {
    [super setUp];
    _monitors = [NSMutableArray array];
    NSMutableArray<VibeTestTransferMonitor *> *monitors = _monitors;
    _registry = [[CloudTransferRegistry alloc] initWithMonitorFactory:
            ^id<VibeCloudTransferMonitor>(NSURL *url, void (^handler)(float), void (^movement)(void)) {
        VibeTestTransferMonitor *monitor = [[VibeTestTransferMonitor alloc] init];
        monitor.url = url;
        monitor.handler = handler;
        monitor.movement = movement;
        [monitors addObject:monitor];
        return monitor;
    }];
    [_registry addObserver:self];
    _observerCallbacks = 0;
}

- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry {
    _observerCallbacks++;
}

- (NSURL *)urlForName:(NSString *)name {
    return [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:name]];
}

- (void)beginForURL:(NSURL *)url {
    [_registry beganTransferForPath:VibeStandardizedAudioOpenPath(url) url:url];
}

- (void)endForURL:(NSURL *)url {
    [_registry endedTransferForPath:VibeStandardizedAudioOpenPath(url)];
}

- (void)drainMainQueue {
    XCTestExpectation *drained = [self expectationWithDescription:@"main drained"];
    dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; });
    [self waitForExpectations:@[drained] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)testBeginAndEndPairKeyedByStandardizedPath {
    NSURL *url = [self urlForName:@"transfer.wav"];
    XCTAssertFalse([_registry isTransferringURL:url]);
    [self beginForURL:url];
    XCTAssertTrue([_registry isTransferringURL:url]);
    XCTAssertEqual([_registry progressForURL:url], -1, @"indeterminate until a fraction lands");
    XCTAssertFalse([_registry isTransferringURL:[self urlForName:@"other.wav"]]);
    [self endForURL:url];
    XCTAssertFalse([_registry isTransferringURL:url]);
}

- (void)testTheRegistrysOwnMonitorFeedsProgress {
    NSURL *url = [self urlForName:@"monitored.wav"];
    [self beginForURL:url];
    XCTAssertEqual(_monitors.count, 1u);
    _monitors.firstObject.handler(0.4f);
    XCTAssertEqualWithAccuracy([_registry progressForURL:url], 0.4f, 0.0001);
}

- (void)testTransferSnapshotProjectsEveryPathAndCurrentFraction {
    NSURL *moving = [self urlForName:@"snapshot-moving.wav"];
    NSURL *indeterminate = [self urlForName:@"snapshot-indeterminate.wav"];
    [self beginForURL:moving];
    [self beginForURL:indeterminate];
    _monitors.firstObject.handler(0.4f);

    NSDictionary<NSString *, NSNumber *> *snapshot = [_registry transferSnapshot];
    XCTAssertEqualObjects(snapshot, (@{
        VibeStandardizedAudioOpenPath(moving): @0.4f,
        VibeStandardizedAudioOpenPath(indeterminate): @-1.0f,
    }));

    [self endForURL:moving];
    XCTAssertEqualObjects([_registry transferSnapshot], (@{
        VibeStandardizedAudioOpenPath(indeterminate): @-1.0f,
    }));
}

// A provider's zero sample is status, not progress.
- (void)testAZeroSampleNeverLeavesOrReentersIndeterminate {
    NSURL *url = [self urlForName:@"status-zero.wav"];
    [self beginForURL:url];
    _monitors.firstObject.handler(0);
    XCTAssertEqual([_registry progressForURL:url], -1, @"zero is not progress");
    _monitors.firstObject.handler(0.3f);
    XCTAssertEqualWithAccuracy([_registry progressForURL:url], 0.3f, 0.0001);
    _monitors.firstObject.handler(0);
    XCTAssertEqualWithAccuracy([_registry progressForURL:url], 0.3f, 0.0001,
            @"a late zero must not blank a fill already shown");
}

- (void)testEndCancelsTheMonitorSoNothingOutlivesItsTransfer {
    NSURL *url = [self urlForName:@"short-lived.wav"];
    [self beginForURL:url];
    [self endForURL:url];
    XCTAssertEqual(_monitors.firstObject.cancelCount, 1u);
    // A fraction already in flight to main when the transfer ended is dropped.
    _monitors.firstObject.handler(0.7f);
    XCTAssertEqual([_registry progressForURL:url], -1);
}

// The coordinator's cancelled-and-readmitted run.
- (void)testAReadmittedRunEndsAndRebegins {
    NSURL *url = [self urlForName:@"readmitted.wav"];
    [self beginForURL:url];
    _monitors.firstObject.handler(0.6f);
    [self endForURL:url];
    [self beginForURL:url];
    XCTAssertEqual(_monitors.count, 2u);
    XCTAssertTrue([_registry isTransferringURL:url]);
    XCTAssertEqual([_registry progressForURL:url], -1,
            @"the restarted transfer starts over; the old fraction is the old run's");
}

- (void)testObserverNotificationsCoalescePerRunloopTurn {
    NSURL *first = [self urlForName:@"one.wav"];
    NSURL *second = [self urlForName:@"two.wav"];
    [self beginForURL:first];
    [self beginForURL:second];
    _monitors.firstObject.handler(0.5f);
    [self drainMainQueue];
    XCTAssertEqual(_observerCallbacks, 1u,
            @"three changes on one turn deliver one callback");
    _monitors.firstObject.handler(0.5f);
    [self drainMainQueue];
    XCTAssertEqual(_observerCallbacks, 1u, @"a fraction already shown changes nothing");
    [self endForURL:second];
    [self drainMainQueue];
    XCTAssertEqual(_observerCallbacks, 2u, @"one per transition, on its own turn");
}

// The row list and the player model both hear every change; a removed or
// released observer hears nothing.
- (void)testEveryObserverHearsEachCoalescedChange {
    VibeTestTransferObserver *model = [[VibeTestTransferObserver alloc] init];
    VibeTestTransferObserver *removed = [[VibeTestTransferObserver alloc] init];
    [_registry addObserver:model];
    [_registry addObserver:removed];
    [_registry removeObserver:removed];
    @autoreleasepool {
        VibeTestTransferObserver *released = [[VibeTestTransferObserver alloc] init];
        [_registry addObserver:released];
    }
    [self beginForURL:[self urlForName:@"observed.wav"]];
    _monitors.firstObject.handler(0.2f);
    [self drainMainQueue];
    XCTAssertEqual(_observerCallbacks, 1u);
    XCTAssertEqual(model.changes, 1u);
    XCTAssertEqual(removed.changes, 0u);
}

// The open deadline's feed: every raw movement, uncoalesced and on the call,
// with the transfer's URL; none once the transfer ended.
- (void)testMovementReachesObserversUncoalescedUntilTheTransferEnds {
    VibeTestTransferObserver *model = [[VibeTestTransferObserver alloc] init];
    model.moves = [NSMutableArray array];
    [_registry addObserver:model];
    NSURL *url = [self urlForName:@"moving.wav"];
    [self beginForURL:url];
    VibeTestTransferMonitor *monitor = _monitors.firstObject;
    monitor.movement();
    monitor.movement();
    XCTAssertEqualObjects(model.moves, (@[url, url]), @"each movement, on the call");
    XCTAssertEqual([_registry progressForURL:url], -1, @"movement is not a fraction");
    [self endForURL:url];
    monitor.movement();
    XCTAssertEqual(model.moves.count, 2u, @"a movement queued past the end is dropped");
}

@end

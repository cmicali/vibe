//
//  CloudTransferRegistryTests.m
//  VibeTests
//
//  The registry with an injected monitor factory, per its Internal.h seam:
//  begin/end pairing, standardized-path keying, the shell's noteProgress:
//  suppressing the registry's own monitor, a cancelled-and-readmitted run
//  ending and re-beginning, and no monitor surviving its transfer.
//

#import <XCTest/XCTest.h>

#import "AudioFileOpenRules.h"
#import "CloudTransferRegistryInternal.h"

@interface VibeTestTransferMonitor : NSObject <VibeCloudTransferMonitor>
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) void (^handler)(float fraction);
@property (nonatomic) NSUInteger cancelCount;
@end

@implementation VibeTestTransferMonitor
- (void)cancel {
    self.cancelCount++;
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
            ^id<VibeCloudTransferMonitor>(NSURL *url, void (^handler)(float)) {
        VibeTestTransferMonitor *monitor = [[VibeTestTransferMonitor alloc] init];
        monitor.url = url;
        monitor.handler = handler;
        [monitors addObject:monitor];
        return monitor;
    }];
    _registry.observer = self;
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
    [self waitForExpectations:@[drained] timeout:1];
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

- (void)testNoteProgressSuppressesTheRegistrysMonitor {
    NSURL *url = [self urlForName:@"shell-fed.wav"];
    [self beginForURL:url];
    VibeTestTransferMonitor *minted = _monitors.firstObject;
    [_registry noteProgress:0.25f forURL:url];
    XCTAssertEqual(minted.cancelCount, 1u,
            @"the shell's monitor owns the path; the registry's would be a second subscription");
    XCTAssertEqualWithAccuracy([_registry progressForURL:url], 0.25f, 0.0001);
    // A late sample from the cancelled monitor must not overwrite the shell's.
    minted.handler(0.9f);
    XCTAssertEqualWithAccuracy([_registry progressForURL:url], 0.25f, 0.0001);
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

// The coordinator's cancelled-and-readmitted run ends and then re-begins;
// the restart gets a fresh monitor and fresh indeterminate progress.
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
    [_registry noteProgress:0.5f forURL:first];
    [self drainMainQueue];
    XCTAssertEqual(_observerCallbacks, 1u,
            @"three changes on one turn deliver one callback");
}

@end

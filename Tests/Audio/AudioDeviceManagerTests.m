//
//  AudioDeviceManagerTests.m
//
//  AudioDeviceManager with injected enumeration and retry scheduling, and no
//  HAL registration: snapshot publication, saved-device lookups and the
//  recovery retry. AudioDeviceEventLog's listener, CoreAudioUtil's bounded
//  reads and device release obligations run with controlled attempts.
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioDeviceEventLog.h"
#import "AudioDeviceManager.h"
#import "CoreAudioUtil.h"

@interface AudioDeviceManagerTests : XCTestCase <AudioDeviceManagerObserver>
@end

@implementation AudioDeviceManagerTests {
    NSArray<AudioDevice *> *_nextDeviceSnapshot;
    NSMutableArray<NSNumber *> *_deviceSweeps;
    NSMutableArray<dispatch_block_t> *_deviceRetries;
    dispatch_block_t _deviceChangeHandler;
}

- (void)audioOutputDevicesDidChange {
    if (_deviceChangeHandler) _deviceChangeHandler();
}

#pragma mark - Device discovery and snapshot lifecycle

- (void)testDeviceEventCallbacksReturnWhilePropertyReadsAreBlockedAndCopyTheirAddresses {
    dispatch_queue_t queue = dispatch_queue_create("test.device-event-log", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    dispatch_semaphore_t returned = dispatch_semaphore_create(0), drained = dispatch_semaphore_create(0);
    NSMutableArray<NSNumber *> *selectors = [NSMutableArray array];
    Method formatter = class_getClassMethod(CoreAudioUtil.class, @selector(eventDescriptionOfProperty:object:));
    IMP replacement = imp_implementationWithBlock(^NSString *(id receiver, AudioObjectPropertyAddress address, AudioObjectID object) {
        XCTAssertEqual(object, 42u);
        XCTAssertEqual(address.mScope, kAudioObjectPropertyScopeGlobal);
        XCTAssertEqual(address.mElement, kAudioObjectPropertyElementMain);
        [selectors addObject:@(address.mSelector)];
        if (selectors.count == 1) {
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        }
        return @"controlled property read";
    });
    IMP original = method_setImplementation(formatter, replacement);
    @try {
        AudioObjectPropertyListenerBlock listener = [AudioDeviceEventLog listenerForObject:42 name:@"test device" queue:queue];
        for (NSNumber *selector in @[@(kAudioDevicePropertyDeviceIsRunning), @(kAudioDeviceProcessorOverload)]) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                AudioObjectPropertyAddress address = {selector.unsignedIntValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                listener(1, &address);
                memset(&address, 0, sizeof(address));
                dispatch_semaphore_signal(returned);
            });
            XCTAssertEqual(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0);
            if (selector.unsignedIntValue == kAudioDevicePropertyDeviceIsRunning) {
                XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0);
            }
        }
    } @finally {
        dispatch_semaphore_signal(release);
        dispatch_async(queue, ^{ dispatch_semaphore_signal(drained); });
        XCTAssertEqual(dispatch_semaphore_wait(drained, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0);
        method_setImplementation(formatter, original);
        imp_removeBlock(replacement);
    }
    XCTAssertEqualObjects(selectors, (@[@(kAudioDevicePropertyDeviceIsRunning), @(kAudioDeviceProcessorOverload)]));
}

- (AudioDevice *)device:(NSInteger)identifier uid:(NSString *)uid name:(NSString *)name {
    return [[AudioDevice alloc] initWithName:name uid:uid deviceId:identifier isSystemDefault:NO transportType:kAudioDeviceTransportTypeUSB];
}

- (AudioDeviceManager *)managerWithSnapshot:(NSArray<AudioDevice *> *)snapshot {
    _nextDeviceSnapshot = snapshot;
    _deviceSweeps = [NSMutableArray array];
    _deviceRetries = [NSMutableArray array];
    XCTestExpectation *started = [self expectationWithDescription:@"initial enumeration"];
    AudioDeviceManager *manager = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) {
        @synchronized (self) {
            [self->_deviceSweeps addObject:@(partial)];
            if (self->_deviceSweeps.count == 1) [started fulfill];
            return self->_nextDeviceSnapshot;
        }
    } retryScheduler:^(NSTimeInterval delay, dispatch_block_t retry) {
        @synchronized (self) {
            XCTAssertEqual(delay, 2);
            [self->_deviceRetries addObject:[retry copy]];
        }
    }];
    [self waitForExpectations:@[started] timeout:VIBE_TEST_HANG_TIMEOUT];
    [manager outputDevices]; // waits out the listener setup
    return manager;
}

- (void)refresh:(AudioDeviceManager *)manager snapshot:(NSArray<AudioDevice *> *)snapshot published:(BOOL)expected {
    @synchronized (self) { _nextDeviceSnapshot = snapshot; }
    XCTestExpectation *done = [self expectationWithDescription:@"refresh completion"];
    [manager refreshOutputDevicesWithCompletion:^(BOOL published) {
        XCTAssertFalse(NSThread.isMainThread);
        XCTAssertEqual(published, expected);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)testUnpublishedSnapshotIsUnknownWhilePublishedEmptyMeansAbsent {
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    XCTAssertEqual(manager.outputDevices.count, 0u);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:42]);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:-1]);
    [self refresh:manager snapshot:@[] published:YES];
    XCTAssertEqual(manager.outputDevices.count, 0u);
    XCTAssertTrue([manager knowsOutputDeviceIsAbsent:42]);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:-1], @"System Output is a policy, never a removed device");
}

- (void)testFailedRefreshRetainsPublishedDevicesAndTheirIdentity {
    AudioDevice *device = [self device:42 uid:@"usb" name:@"DAC"];
    AudioDeviceManager *manager = [self managerWithSnapshot:@[device]];
    [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqualObjects(manager.outputDevices, @[device]);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:42]);
    XCTAssertEqual([manager outputDeviceForId:42], device);
    [self refresh:manager snapshot:@[] published:YES];
    XCTAssertTrue([manager knowsOutputDeviceIsAbsent:42]);
    XCTAssertNil([manager outputDeviceForId:42]);
}

- (void)testPublishedDeviceArrayCannotBeMutatedThroughEnumerationResult {
    AudioDevice *device = [self device:42 uid:@"usb" name:@"DAC"];
    NSMutableArray *enumerated = [NSMutableArray arrayWithObject:device];
    AudioDeviceManager *manager = [self managerWithSnapshot:enumerated];
    [enumerated removeAllObjects];
    XCTAssertEqualObjects(manager.outputDevices, @[device]);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:42]);
}

- (void)testPartialSweepStartsAfterThreeFailuresAndSuccessResetsTheBudget {
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    [self refresh:manager snapshot:nil published:NO];
    [self refresh:manager snapshot:nil published:NO];
    [self refresh:manager snapshot:@[] published:YES];
    [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqualObjects(_deviceSweeps, (@[@NO, @NO, @NO, @YES, @NO]));
    XCTAssertEqual(_deviceRetries.count, 1u, @"Repeated failures share the outstanding retry");
}

- (void)testEvenPartialEnumerationFailureCannotPublishFalseRemoval {
    AudioDevice *device = [self device:42 uid:@"usb" name:@"DAC"];
    AudioDeviceManager *manager = [self managerWithSnapshot:@[device]];
    for (NSUInteger i = 0; i < 5; i++) [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqualObjects(_deviceSweeps.lastObject, @YES);
    XCTAssertEqualObjects(manager.outputDevices, @[device]);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:42]);
}

- (void)testPendingSavedDeviceLookupsDrainExactlyOnceAfterRecovery {
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    AudioDevice *device = [self device:42 uid:@"usb" name:@"DAC"];
    XCTestExpectation *resolved = [self expectationWithDescription:@"both waiters"];
    resolved.expectedFulfillmentCount = 2;
    __block NSUInteger deliveries = 0;
    for (NSUInteger i = 0; i < 2; i++) {
        [manager resolveOutputDeviceForUID:@"usb" name:@"DAC" completion:^(AudioDevice *answer) {
            XCTAssertFalse(NSThread.isMainThread);
            XCTAssertEqual(answer, device);
            deliveries++;
            [resolved fulfill];
        }];
    }
    [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqual(deliveries, 0u);
    [self refresh:manager snapshot:@[device] published:YES];
    [self waitForExpectations:@[resolved] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self refresh:manager snapshot:@[] published:YES];
    XCTAssertEqual(deliveries, 2u);
}

#pragma mark - Carrying remembered modes to a new USB port

static NSString *const kModesKey = @"AudioPlayer.outputModesByDeviceUID";

// Removed rather than restored: writing a value back would materialize a key
// that was never there (Tests/AGENTS.md). The guard restores the domain at exit.
- (void)withModeStore:(NSDictionary *)store run:(void (^)(void))block {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:store forKey:kModesKey];
    block();
    [defaults removeObjectForKey:kModesKey];
}

- (void)testCarryCopiesModesToTheNewPortAndLeavesTheOldPortIntact {
    [self withModeStore:@{@"port-a": @{@"bitPerfect": @YES, @"exclusive": @YES}} run:^{
        AppSettings *settings = AppSettings.sharedInstance;
        [settings carryOutputModesFromDeviceUID:@"port-a" toDeviceUID:@"port-b"];
        XCTAssertTrue([settings bitPerfectOutputForDeviceUID:@"port-b"]);
        XCTAssertTrue([settings exclusiveOutputForDeviceUID:@"port-b"]);
        // Copied, not moved: plugged back into the first port it still has them.
        XCTAssertTrue([settings bitPerfectOutputForDeviceUID:@"port-a"]);
    }];
}

// Modes someone already chose for that exact unit are a choice; a carry is a
// guess, and must never overwrite a choice.
- (void)testCarryNeverOverwritesModesAlreadyChosenForTheDestination {
    [self withModeStore:@{@"port-a": @{@"bitPerfect": @YES},
                          @"port-b": @{@"exclusive": @YES}} run:^{
        AppSettings *settings = AppSettings.sharedInstance;
        [settings carryOutputModesFromDeviceUID:@"port-a" toDeviceUID:@"port-b"];
        XCTAssertFalse([settings bitPerfectOutputForDeviceUID:@"port-b"]);
        XCTAssertTrue([settings exclusiveOutputForDeviceUID:@"port-b"]);
    }];
}

- (void)testCarryIgnoresEmptyOrIdenticalUIDs {
    [self withModeStore:@{@"port-a": @{@"bitPerfect": @YES}} run:^{
        AppSettings *settings = AppSettings.sharedInstance;
        [settings carryOutputModesFromDeviceUID:@"" toDeviceUID:@"port-b"];
        [settings carryOutputModesFromDeviceUID:@"port-a" toDeviceUID:@""];
        [settings carryOutputModesFromDeviceUID:@"port-a" toDeviceUID:@"port-a"];
        XCTAssertFalse([settings bitPerfectOutputForDeviceUID:@"port-b"]);
        XCTAssertEqual([[NSUserDefaults.standardUserDefaults dictionaryForKey:kModesKey] count], 1u);
    }];
}

// A class-compliant USB interface's device UID is its USB location, so the same
// iD4 on another port has a new UID but the same model UID.
- (void)testSavedDeviceIsFoundByModelUIDWhenMovedToAnotherPort {
    AudioDevice *moved = [[AudioDevice alloc] initWithName:@"Audient iD4"
            uid:@"AppleUSBAudioEngine:Audient:Audient iD4:1100000:1,2"
            modelUID:@"Audient iD4:2708:0009" deviceId:7 isSystemDefault:NO
            transportType:kAudioDeviceTransportTypeUSB];
    AudioDevice *found = [AudioDeviceManager
            deviceForUID:@"AppleUSBAudioEngine:Audient:Audient iD4:2100000:1,2"
                modelUID:@"Audient iD4:2708:0009" name:@"Audient iD4" inDevices:@[moved]];
    XCTAssertEqual(found, moved);
}

// The model UID outranks the name because it tells apart two models that share
// a name; the name cannot. Otherwise the wrong one could inherit exclusive.
- (void)testModelUIDOutranksAMatchingName {
    AudioDevice *impostor = [[AudioDevice alloc] initWithName:@"Audient iD4" uid:@"other"
            modelUID:@"Someone Else:1234:0001" deviceId:1 isSystemDefault:NO
            transportType:kAudioDeviceTransportTypeUSB];
    AudioDevice *real = [[AudioDevice alloc] initWithName:@"Audient iD4" uid:@"new-port"
            modelUID:@"Audient iD4:2708:0009" deviceId:2 isSystemDefault:NO
            transportType:kAudioDeviceTransportTypeUSB];
    AudioDevice *found = [AudioDeviceManager deviceForUID:@"old-port" modelUID:@"Audient iD4:2708:0009"
                                                     name:@"Audient iD4" inDevices:@[impostor, real]];
    XCTAssertEqual(found, real);
}

// Device UID is still the most specific answer and wins over a model match.
- (void)testDeviceUIDOutranksModelUID {
    AudioDevice *sibling = [[AudioDevice alloc] initWithName:@"Audient iD4" uid:@"port-a"
            modelUID:@"Audient iD4:2708:0009" deviceId:1 isSystemDefault:NO
            transportType:kAudioDeviceTransportTypeUSB];
    AudioDevice *exact = [[AudioDevice alloc] initWithName:@"Audient iD4" uid:@"port-b"
            modelUID:@"Audient iD4:2708:0009" deviceId:2 isSystemDefault:NO
            transportType:kAudioDeviceTransportTypeUSB];
    AudioDevice *found = [AudioDeviceManager deviceForUID:@"port-b" modelUID:@"Audient iD4:2708:0009"
                                                     name:@"Audient iD4" inDevices:@[sibling, exact]];
    XCTAssertEqual(found, exact);
}

// An empty model UID must never match a device that also reports none.
- (void)testEmptyModelUIDNeverMatches {
    AudioDevice *unnamed = [[AudioDevice alloc] initWithName:@"Virtual" uid:@"v"
            modelUID:@"" deviceId:1 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    XCTAssertNil([AudioDeviceManager deviceForUID:@"gone" modelUID:@"" name:@"" inDevices:@[unnamed]]);
}

- (void)testSavedDeviceResolutionPrefersUIDThenFallsBackToName {
    AudioDevice *a = [self device:1 uid:@"a" name:@"DAC"];
    AudioDevice *b = [self device:2 uid:@"b" name:@"DAC"];
    AudioDeviceManager *manager = [self managerWithSnapshot:@[a, b]];
    NSArray *cases = @[@[@"b", @"DAC", b], @[@"unknown", @"DAC", a], @[@"", @"DAC", a],
                       @[@"a", @"renamed", a], @[@"unknown", @"missing", NSNull.null]];
    XCTestExpectation *resolved = [self expectationWithDescription:@"UID/name resolutions"];
    resolved.expectedFulfillmentCount = cases.count;
    for (NSArray *row in cases) {
        [manager resolveOutputDeviceForUID:row[0] name:row[1] completion:^(AudioDevice *answer) {
            XCTAssertEqualObjects(answer ?: NSNull.null, row[2]);
            [resolved fulfill];
        }];
    }
    [self waitForExpectations:@[resolved] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)testAuthoritativeEmptySnapshotCompletesAnUnmatchedLookup {
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    XCTestExpectation *resolved = [self expectationWithDescription:@"no match"];
    __block NSUInteger deliveries = 0;
    [manager resolveOutputDeviceForUID:@"missing" name:@"DAC" completion:^(AudioDevice *answer) {
        XCTAssertNil(answer);
        deliveries++;
        [resolved fulfill];
    }];
    [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqual(deliveries, 0u, @"Unknown discovery must not disable an armed mode");
    [self refresh:manager snapshot:@[] published:YES];
    [self waitForExpectations:@[resolved] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self refresh:manager snapshot:@[] published:YES];
    XCTAssertEqual(deliveries, 1u);
}

- (void)testRecoveryTimerPublishesBeforeMainThreadObserversRun {
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    AudioDevice *device = [self device:42 uid:@"usb" name:@"DAC"];
    XCTestExpectation *notified = [self expectationWithDescription:@"recovery observer"];
    _deviceChangeHandler = ^{
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqualObjects(manager.outputDevices, @[device]);
        [notified fulfill];
    };
    [manager addObserver:self];
    @synchronized (self) { _nextDeviceSnapshot = @[device]; }
    dispatch_block_t retry = _deviceRetries.firstObject;
    retry();
    [self waitForExpectations:@[notified] timeout:VIBE_TEST_HANG_TIMEOUT];
    [manager removeObserver:self];
    _deviceChangeHandler = nil;
    [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqual(_deviceRetries.count, 2u, @"Completed timer releases the retry slot");
}

#pragma mark - Format restore / exclusive release obligations

- (void)testSuccessfulDeviceCleanupClearsSlotWithoutAnAbsenceReadOrRetry {
    AudioDeviceID deviceID = 42;
    __block NSUInteger attempts = 0;
    XCTAssertTrue([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ attempts++; return YES; }
            isAbsent:^BOOL(AudioDeviceID identifier) { XCTFail(@"Successful write settled it"); return NO; }]);
    XCTAssertEqual(deviceID, kAudioObjectUnknown);
    XCTAssertEqual(attempts, 1u);
}

- (void)testDeviceCleanupRetriesOnceAndRetainsFailureForTheNextLeave {
    AudioDeviceID deviceID = 42;
    __block NSUInteger attempts = 0;
    BOOL (^unknownOrPresent)(AudioDeviceID) = ^BOOL(AudioDeviceID identifier) { XCTAssertEqual(identifier, 42u); return NO; };
    XCTAssertFalse([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ attempts++; return NO; } isAbsent:unknownOrPresent]);
    XCTAssertEqual(attempts, 2u);
    XCTAssertEqual(deviceID, 42u, @"An uncertain restore must not forget which device is owed");
    attempts = 0;
    XCTAssertTrue([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ return ++attempts == 2; } isAbsent:unknownOrPresent]);
    XCTAssertEqual(attempts, 2u);
    XCTAssertEqual(deviceID, kAudioObjectUnknown);
}

- (void)testConfirmedRemovalRetiresCleanupWhileUnknownDiscoveryKeepsIt {
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    AudioDeviceID deviceID = 42;
    BOOL (^absent)(AudioDeviceID) = ^BOOL(AudioDeviceID identifier) { return [manager knowsOutputDeviceIsAbsent:identifier]; };
    XCTAssertFalse([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ return NO; } isAbsent:absent]);
    XCTAssertEqual(deviceID, 42u);
    [self refresh:manager snapshot:@[] published:YES];
    __block NSUInteger attempts = 0;
    XCTAssertTrue([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ attempts++; return NO; } isAbsent:absent]);
    XCTAssertEqual(attempts, 1u);
    XCTAssertEqual(deviceID, kAudioObjectUnknown);
}

- (void)testEmptyDeviceObligationTouchesNoHardwareOrDiscovery {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    XCTAssertTrue([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ XCTFail(@"No device to restore"); return NO; }
            isAbsent:^BOOL(AudioDeviceID identifier) { XCTFail(@"No discovery needed"); return NO; }]);
}

#pragma mark - Bounded reads and the first snapshot

- (void)testABoundedReadAnswersInTimeOrLeavesItsAnswerToLate {
    __block int value = 0;
    XCTAssertTrue([CoreAudioUtil performBoundedRead:^{ value = 7; } within:1 late:^{ XCTFail(@"answered in time"); }]);
    XCTAssertEqual(value, 7);

    dispatch_semaphore_t hung = dispatch_semaphore_create(0);
    XCTestExpectation *late = [self expectationWithDescription:@"the late answer"];
    uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    XCTAssertFalse([CoreAudioUtil performBoundedRead:^{
        dispatch_semaphore_wait(hung, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
    } within:0.05 late:^{ [late fulfill]; }]);
    double waited = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1e6;
    XCTAssertGreaterThanOrEqual(waited, 45.0);
    // The hung read is held for the gate, so only a caller that waited on it
    // could take longer than the guard.
    XCTAssertLessThan(waited, VIBE_TEST_HANG_TIMEOUT * 1000.0, @"the caller waited on the hung read");
    began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    XCTAssertFalse([CoreAudioUtil performBoundedRead:^{} within:VIBE_TEST_GATE_TIMEOUT late:nil]);
    XCTAssertLessThan((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1e6, VIBE_TEST_HANG_TIMEOUT * 1000.0,
                      @"a read queued behind an overdue one must not wait for it");
    dispatch_semaphore_signal(hung);
    [self waitForExpectations:@[late] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue([CoreAudioUtil performBoundedRead:^{} within:1 late:nil], @"the queue waits again once it drained");
}

// The player queue asks during setup too: it must get "unknown" at once, not
// the setup's 250 ms ceiling.
- (void)testAbsenceDoesNotWaitForTheFirstSnapshot {
    dispatch_semaphore_t publish = dispatch_semaphore_create(0);
    AudioDeviceManager *manager = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) {
        dispatch_semaphore_wait(publish, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        return @[];
    } retryScheduler:nil];
    uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:42]);
    XCTAssertNil([manager outputDeviceForId:42]);
    XCTAssertLessThan((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1e6, 100.0);
    dispatch_semaphore_signal(publish);
    (void)manager.outputDevices;
    XCTAssertTrue([manager knowsOutputDeviceIsAbsent:42]);
}

@end

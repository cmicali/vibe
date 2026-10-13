//
//  AudioPlayerRenderDeviceTests.m
//

#import "AudioPlayerRenderTestCase.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import <objc/runtime.h>

// Saved, fallback and launch devices, and the modes carried between them.
@interface AudioPlayerRenderDeviceTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderDeviceTests

- (void)testSavedDeviceFailureDoesNotReenter {
    AudioDevice *device = [[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"saved" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[device]; } retryScheduler:nil];
    (void)devices.outputDevices;
    __block NSUInteger binds = 0;
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getInstanceMethod(AudioPlayer.class, @selector(setOutputUnitDevice:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^BOOL(AudioPlayer *player, AudioDeviceID deviceID) {
            binds++;
            if (binds == 4) {
                [player setValue:nil forKey:@"pendingSavedDeviceUID"];
                [player setValue:nil forKey:@"pendingSavedDeviceName"];
            }
            return NO;
        }),
    };
    IMP originals[3];
    for (NSUInteger i=0;i<3;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"saved" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"pendingSavedDeviceName"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
        }];
        XCTAssertEqual(binds, 1u, @"a refused saved-device bind is tried once: the guard held across it keeps the reset to Stopped from resolving again (the stub ends a regression at four)");
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<3;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testFallbackSurvivesDefaultChange {
    AudioDevice *device = [[AudioDevice alloc] initWithName:@"Speakers" uid:@"speakers" deviceId:1 isSystemDefault:YES transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[device]; } retryScheduler:nil];
    (void)devices.outputDevices;
    NSMutableArray *announcements = [NSMutableArray array];
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getClassMethod(CoreAudioUtil.class, @selector(readSystemDefaultOutputDeviceID:)),
        class_getInstanceMethod(AudioPlayerRenderTests.class, @selector(audioPlayer:didChangeOutputDevice:involuntaryFallbackUID:involuntaryFallbackName:carriedModesFromUID:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^BOOL(id cls, AudioDeviceID *out) { *out=1; return YES; }),
        imp_implementationWithBlock(^(id test, AudioPlayer *player, NSInteger deviceID, NSString *fallbackUID, NSString *fallbackName, NSString *carriedUID) {
            [announcements addObject:@{@"device":@(deviceID), @"fallback":fallbackUID ?: @""}];
        }),
    };
    IMP originals[4];
    for(NSUInteger i=0;i<4;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [_player runSyncOnQueue:^{
            self->_player.currentlyRequestedAudioDeviceId=2;
            [self->_player setValue:@"saved" forKey:@"boundDeviceUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"boundDeviceName"];
        }];
        [_player audioOutputDevicesDidChange];
        [self settleUntil:^BOOL { return announcements.count >= 1; }];
        XCTAssertEqualObjects(announcements[0][@"fallback"], @"saved");
        [_player systemDefaultOutputDeviceDidChange];
        [self settleUntil:^BOOL { return announcements.count >= 2; }];
        XCTAssertEqualObjects(announcements[1][@"fallback"], @"saved", @"A second involuntary notification must not look like user-selected System Output");
        __block BOOL selected = NO;
        [_player setOutputDevice:-1 completion:^{ selected = YES; }];
        [self settleUntil:^BOOL { return selected; }];
        XCTAssertEqualObjects(announcements.lastObject[@"fallback"], @"");
        XCTAssertEqualObjects(_player.outputDeviceDiagnosticSnapshot[@"pendingDeviceUID"], @"");
    } @finally {
        [_player runSyncOnQueue:^{
            [self->_player setValue:nil forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:nil forKey:@"pendingSavedDeviceName"];
        }];
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<4;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testModelMatchRespectsDestinationModes {
    AudioDevice *device = [[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"port-b" modelUID:@"model" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[device]; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method method=class_getClassMethod(AudioDeviceManager.class,@selector(sharedInstance));
    IMP replacement=imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; });
    IMP original=method_setImplementation(method,replacement);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        _outputModesProvider=^(NSString *uid, BOOL *bitPerfect, BOOL *exclusive) {
            *bitPerfect=YES;
            *exclusive=[uid isEqualToString:@"port-a"];
        };
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"port-a" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"model" forKey:@"pendingSavedDeviceModelUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"pendingSavedDeviceName"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
        }];
        __block BOOL exclusive;
        [_player runSyncOnQueue:^{ exclusive=[[self->_player valueForKey:@"exclusiveOutputWanted"] boolValue]; }];
        XCTAssertFalse(exclusive, @"Port B already has bit-perfect on and exclusive off");
        [self settleUntil:^BOOL { return [self count:@"device"] == 1; }];
        XCTAssertEqualObjects(_events.lastObject[@"carriedModes"], @"");
        // An unconfigured destination inherits only on automatic re-adoption.
        _outputModesProvider = ^(NSString *uid, BOOL *bitPerfect, BOOL *exclusive) {
            *bitPerfect = *exclusive = [uid isEqualToString:@"port-a"];
        };
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"port-a" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"model" forKey:@"pendingSavedDeviceModelUID"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
        }];
        [self settleUntil:^BOOL { return [self count:@"device"] == 2; }];
        XCTAssertTrue([_player.outputDeviceDiagnosticSnapshot[@"exclusiveOutputWanted"] boolValue]);
        XCTAssertEqualObjects(_events.lastObject[@"carriedModes"], @"port-a");
        __block BOOL selected = NO;
        [_player setOutputDevice:2 completion:^{ selected = YES; }];
        [self settleUntil:^BOOL { return selected; }];
        XCTAssertFalse([_player.outputDeviceDiagnosticSnapshot[@"exclusiveOutputWanted"] boolValue]);
        XCTAssertEqualObjects(_events.lastObject[@"carriedModes"], @"");
    } @finally {
        [_player debugShutdown]; _player=nil;
        method_setImplementation(method,original); imp_removeBlock(replacement);
    }
}

- (void)testAbsentLaunchDeviceRemainsPending {
    __block NSArray *snapshot = @[];
    AudioDeviceManager *devices=[[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return snapshot; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method methods[]={class_getClassMethod(AudioDeviceManager.class,@selector(sharedInstance)), class_getClassMethod(CoreAudioUtil.class,@selector(readSystemDefaultOutputDeviceID:))};
    IMP replacements[]={imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }), imp_implementationWithBlock(^BOOL(id cls, AudioDeviceID *out) { *out=0; return YES; })};
    IMP originals[2]; for(NSUInteger i=0;i<2;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"saved" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"pendingSavedDeviceName"];
            [self->_player setValue:@YES forKey:@"bitPerfectWanted"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
        }];
        [self settleUntil:^BOOL {
            __block BOOL pending;
            [self->_player runSyncOnQueue:^{ pending=[[self->_player valueForKey:@"pendingSavedDeviceLookupInFlight"] boolValue]; }];
            return !pending;
        }];
        __block NSString *wanted;
        [_player runSyncOnQueue:^{ wanted=[self->_player valueForKey:@"pendingSavedDeviceUID"]; }];
        XCTAssertEqualObjects(wanted,@"saved",@"Device must be re-adoptable when powered on later this session");
        snapshot = @[[[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"saved" deviceId:2
                isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual]];
        XCTestExpectation *published = [self expectationWithDescription:@"device returned"];
        [devices refreshOutputDevicesWithCompletion:^(BOOL success) { [published fulfill]; }];
        [self waitForExpectations:@[published] timeout:VIBE_TEST_HANG_TIMEOUT];
        [_player audioOutputDevicesDidChange];
        [_player runSyncOnQueue:^{}];
        XCTAssertEqual(_player.currentlyRequestedAudioDeviceId, 2);
        XCTAssertEqualObjects(_player.outputDeviceDiagnosticSnapshot[@"pendingDeviceUID"], @"");
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<2;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}
- (void)testTerminationCannotRestartOnDeviceCallbacks {
    AudioDevice *device=[[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"saved" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices=[[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[device]; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method methods[]={class_getClassMethod(AudioDeviceManager.class,@selector(sharedInstance)),class_getClassMethod(CoreAudioUtil.class,@selector(deviceIsConfirmedDead:))};
    IMP replacements[]={imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),imp_implementationWithBlock(^BOOL(id cls,AudioDeviceID deviceID) { return NO; })};
    IMP originals[2]; for(NSUInteger i=0;i<2;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
        [self render:4096];
        [_player runSyncOnQueue:^{
            self->_player.currentlyRequestedAudioDeviceId=2;
            [self->_player setValue:@2 forKey:@"preparedDeviceID"];
        }];
        XCTAssertTrue(_player.isPlaying);
        XCTAssertEqual([self count:@"finish"],0u);
        [_player prepareForTermination];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        XCTAssertEqual([self count:@"finish"],0u,@"Termination must not deliver natural track-end and auto-advance during NSTerminateLater");
        XCTAssertFalse([_player.debugRenderCounts[@"running"] boolValue]);
        AudioTrack *lateTrack = [[AudioTrack alloc] initWithURL:[self fixture:@"noise-48000-24-2.wav"]];
        [_player play:lateTrack];
        [_player prefetchTrack:lateTrack];
        [_player setBitPerfectOutput:YES exclusiveOutput:YES enableFX:NO allowAnyDevice:NO];
        [_player audioOutputDevicesDidChange];
        [_player systemDefaultOutputDeviceDidChange];
        [_player runSyncOnQueue:^{}];
        XCTAssertTrue(_player.isStopped);
        XCTAssertFalse([_player.outputDeviceDiagnosticSnapshot[@"outputRunning"] boolValue]);
        XCTAssertNil([_player valueForKey:@"playOpenToken"]);
        XCTAssertNil([_player valueForKey:@"prefetchOpenToken"]);
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<2;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testSavedDeviceDiscoveryCannotUndoExplicitSystemOutput {
    AudioDevice *device = [[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"saved" deviceId:2
            isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    dispatch_semaphore_t publish = dispatch_semaphore_create(0);
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) {
        dispatch_semaphore_wait(publish, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        return @[device];
    } retryScheduler:nil];
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(readSystemDefaultOutputDeviceID:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^BOOL(id cls, AudioDeviceID *out) { *out = 0; return YES; }),
    };
    IMP originals[2];
    for (NSUInteger i = 0; i < 2; i++) originals[i] = method_setImplementation(methods[i], replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"saved" forKey:@"pendingSavedDeviceUID"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
        }];
        XCTAssertTrue([_player.outputDeviceDiagnosticSnapshot[@"savedDeviceLookupInFlight"] boolValue]);
        __block BOOL selected = NO;
        [_player setOutputDevice:-1 completion:^{ selected = YES; }];
        [self settleUntil:^BOOL { return selected; }];
        dispatch_semaphore_signal(publish);
        [self settleUntil:^BOOL {
            return ![self->_player.outputDeviceDiagnosticSnapshot[@"savedDeviceLookupInFlight"] boolValue];
        }];
        XCTAssertEqual(_player.currentlyRequestedAudioDeviceId, -1);
        XCTAssertEqualObjects(_player.outputDeviceDiagnosticSnapshot[@"pendingDeviceUID"], @"");
    } @finally {
        dispatch_semaphore_signal(publish);
        [_player debugShutdown]; _player = nil;
        for (NSUInteger i = 0; i < 2; i++) {
            method_setImplementation(methods[i], originals[i]);
            imp_removeBlock(replacements[i]);
        }
    }
}

- (void)testFailedManualSelectionDoesNotOverwriteReadoptedModes {
    AudioDevice *a = [[AudioDevice alloc] initWithName:@"A" uid:@"a" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDevice *b = [[AudioDevice alloc] initWithName:@"B" uid:@"b" deviceId:3 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[a,b]; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getInstanceMethod(AudioPlayer.class, @selector(setOutputUnitDevice:)),
    };
    NSMutableArray *binds = [NSMutableArray array];
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^BOOL(AudioPlayer *p, AudioDeviceID d) { [binds addObject:@(d)]; return d != 3; }),
    };
    IMP originals[3];
    for (NSUInteger i=0;i<3;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
        [self render:4096];
        _outputModesProvider=^(NSString *uid, BOOL *bp, BOOL *exclusive) { *bp=*exclusive=[uid isEqualToString:@"a"]; };
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"a" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"A" forKey:@"pendingSavedDeviceName"];
        }];
        __block BOOL selected=NO;
        [_player setOutputDevice:3 completion:^{ selected=YES; }];
        [self settleUntil:^BOOL { return selected; }];
        NSDictionary *snapshot=_player.outputDeviceDiagnosticSnapshot;
        XCTAssertEqual(_player.currentlyRequestedAudioDeviceId, 2);
        XCTAssertTrue([snapshot[@"bitPerfectWanted"] boolValue], @"A was adopted with its modes but B's rollback overwrote them: %@, binds %@",snapshot,binds);
        XCTAssertTrue([snapshot[@"exclusiveOutputWanted"] boolValue]);
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<3;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testFailedReadoptionAtTrackEndStillDeliversFinish {
    AudioDevice *a = [[AudioDevice alloc] initWithName:@"A" uid:@"a" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[a]; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getInstanceMethod(AudioPlayer.class, @selector(setOutputUnitDevice:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^BOOL(AudioPlayer *p, AudioDeviceID d) { return NO; }),
    };
    IMP originals[3];
    for(NSUInteger i=0;i<3;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
        [self render:4096];
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"a" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"A" forKey:@"pendingSavedDeviceName"];
        }];
        [self render:100000];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"],1u,@"Device bind failure must not eat the completed track's end: %@",_events);
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<3;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testMissingLastOutputParksWithoutFinishingTrack {
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[]; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getClassMethod(CoreAudioUtil.class, @selector(readSystemDefaultOutputDeviceID:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return kAudioObjectUnknown; }),
        imp_implementationWithBlock(^BOOL(id cls, AudioDeviceID *out) { *out=kAudioObjectUnknown; return YES; }),
    };
    IMP originals[3];
    for(NSUInteger i=0;i<3;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
        [self render:4096];
        [_player runSyncOnQueue:^{
            self->_player.currentlyRequestedAudioDeviceId=2;
            [self->_player setValue:@"saved" forKey:@"boundDeviceUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"boundDeviceName"];
        }];
        [_player audioOutputDevicesDidChange];
        [self settleUntil:^BOOL { return self->_player.isPaused || [self count:@"finish"] > 0; }];
        [_player runSyncOnQueue:^{}];
        XCTAssertEqual([self count:@"finish"],0u,@"Losing the last output must park the track, not auto-advance: %@",_events);
        XCTAssertTrue(_player.isPaused,@"The track must remain resumable: %@",_events);
        double parked = _player.position;
        XCTAssertGreaterThan(parked, 0);
        [_player resume];
        [self settleUntil:^BOOL { return [self count:@"resume"] == 1; }];
        [self render:100000];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"],1u,@"The replacement schedule must finish exactly once after resume");
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<3;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testQueuedFXEditKeepsModesCarriedToNewPort {
    AudioDevice *device = [[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"port-b" modelUID:@"model" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[device]; } retryScheduler:nil];
    (void)devices.outputDevices;
    NSMutableDictionary *savedModes = [@{@"port-a": @YES} mutableCopy];
    __block BOOL carryDelivered = NO;
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getInstanceMethod(AudioPlayerRenderTests.class, @selector(audioPlayer:didChangeOutputDevice:involuntaryFallbackUID:involuntaryFallbackName:carriedModesFromUID:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^(id test, AudioPlayer *player, NSInteger deviceID, NSString *fallbackUID, NSString *fallbackName, NSString *source) {
            if (source.length) {
                @synchronized(savedModes) { savedModes[@"port-b"] = savedModes[source]; }
                carryDelivered = YES;
            }
        }),
    };
    IMP originals[3];
    for(NSUInteger i=0;i<3;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        _outputModesProvider=^(NSString *uid, BOOL *bp, BOOL *exclusive) {
            @synchronized(savedModes) { *bp=*exclusive=[savedModes[uid ?: @""] boolValue]; }
        };
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"port-a" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"model" forKey:@"pendingSavedDeviceModelUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"pendingSavedDeviceName"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
            [self->_player setBitPerfectOutput:YES exclusiveOutput:YES enableFX:YES allowAnyDevice:NO];
        }];
        // Keep main occupied until the previously queued settings edit lands.
        [_player runSyncOnQueue:^{}];
        [self settleUntil:^BOOL { return carryDelivered; }];
        XCTAssertEqual(_player.currentlyRequestedAudioDeviceId,2);
        XCTAssertTrue([savedModes[@"port-b"] boolValue]);
        NSDictionary *snapshot=_player.outputDeviceDiagnosticSnapshot;
        XCTAssertTrue([snapshot[@"bitPerfectWanted"] boolValue],@"A queued global edit must preserve adopted modes even before their main-thread persistence: %@",snapshot);
        XCTAssertTrue([snapshot[@"exclusiveOutputWanted"] boolValue]);
        @synchronized(savedModes) { savedModes[@"port-b"] = @NO; }
        [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:YES allowAnyDevice:NO];
        [_player runSyncOnQueue:^{}];
        XCTAssertFalse([_player.outputDeviceDiagnosticSnapshot[@"bitPerfectWanted"] boolValue], @"Once persisted, the destination's later edits must win");
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<3;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

@end

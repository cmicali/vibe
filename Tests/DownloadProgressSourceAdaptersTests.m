//
//  DownloadProgressSourceAdaptersTests.m
//

#import <XCTest/XCTest.h>

#import "DownloadProgressSourceAdaptersInternal.h"

#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

@interface FakeDownloadMetadataItem : NSObject

@property(nonatomic, copy) NSURL *URL;
@property(nonatomic, copy, nullable) NSNumber *percent;

- (instancetype)initWithURL:(NSURL *)URL percent:(NSNumber *_Nullable)percent;
- (id _Nullable)valueForAttribute:(NSString *)attribute;

@end


@implementation FakeDownloadMetadataItem

- (instancetype)initWithURL:(NSURL *)URL percent:(NSNumber *_Nullable)percent {
    self = [super init];
    if (self) {
        _URL = [URL copy];
        _percent = [percent copy];
    }
    return self;
}

- (id)valueForAttribute:(NSString *)attribute {
    if ([attribute isEqualToString:NSMetadataItemURLKey]) {
        return self.URL;
    }
    if ([attribute isEqualToString:NSMetadataUbiquitousItemPercentDownloadedKey]) {
        return self.percent;
    }
    return nil;
}

@end


@interface FakeDownloadMetadataQuery : NSMetadataQuery {
    NSArray *_fakeSearchScopes;
    NSPredicate *_fakePredicate;
}

@property(nonatomic) BOOL startSucceeds;
@property(nonatomic) NSUInteger startCount;
@property(nonatomic) NSUInteger stopCount;
@property(nonatomic) NSUInteger disableCount;
@property(nonatomic) NSUInteger enableCount;
@property(nonatomic, copy) NSArray<FakeDownloadMetadataItem *> *items;

@end


@implementation FakeDownloadMetadataQuery

- (instancetype)init {
    self = [super init];
    if (self) {
        _startSucceeds = YES;
        _items = @[];
    }
    return self;
}

- (void)setSearchScopes:(NSArray *)searchScopes {
    _fakeSearchScopes = [searchScopes copy];
}

- (NSArray *)searchScopes {
    return _fakeSearchScopes;
}

- (void)setPredicate:(NSPredicate *)predicate {
    _fakePredicate = [predicate copy];
}

- (NSPredicate *)predicate {
    return _fakePredicate;
}

- (BOOL)startQuery {
    self.startCount++;
    return self.startSucceeds;
}

- (void)stopQuery {
    self.stopCount++;
}

- (void)disableUpdates {
    self.disableCount++;
}

- (void)enableUpdates {
    self.enableCount++;
}

- (NSUInteger)resultCount {
    return self.items.count;
}

- (id)resultAtIndex:(NSUInteger)index {
    return self.items[index];
}

@end

@interface DownloadProgressSourceAdaptersTests : XCTestCase
@end

@implementation DownloadProgressSourceAdaptersTests {
    NSURL *_fixtureDirectory;
    NSMutableArray<DownloadAllocatedSizeSource *> *_sources;
    NSMutableArray *_otherSources;
}

- (void)setUp {
    [super setUp];
    _fixtureDirectory = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
            URLByAppendingPathComponent:[NSUUID UUID].UUIDString isDirectory:YES];
    NSError *error = nil;
    XCTAssertTrue([NSFileManager.defaultManager
            createDirectoryAtURL:_fixtureDirectory
      withIntermediateDirectories:YES attributes:nil error:&error]);
    XCTAssertNil(error);
    _sources = [NSMutableArray array];
    _otherSources = [NSMutableArray array];
}

- (void)tearDown {
    for (DownloadAllocatedSizeSource *source in _sources) {
        [source cancel];
    }
    for (id source in _otherSources) {
        [source cancel];
    }
    [NSFileManager.defaultManager removeItemAtURL:_fixtureDirectory error:NULL];
    [super tearDown];
}

- (NSURL *)URLNamed:(NSString *)name {
    return [_fixtureDirectory URLByAppendingPathComponent:name];
}

- (BOOL)writeAllocatedBytesToURL:(NSURL *)url length:(NSUInteger)length {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    arc4random_buf(data.mutableBytes, data.length);
    return [data writeToURL:url atomically:YES];
}

- (void)runMainLoopUntil:(BOOL *)condition timeout:(NSTimeInterval)timeout {
    XCTAssertTrue(NSThread.isMainThread);
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (!*condition && NSProcessInfo.processInfo.systemUptime < deadline) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertTrue(*condition);
}

- (void)runMainLoopUntilBlock:(BOOL (^)(void))condition
                       timeout:(NSTimeInterval)timeout {
    XCTAssertTrue(NSThread.isMainThread);
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (!condition() && NSProcessInfo.processInfo.systemUptime < deadline) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertTrue(condition());
}

- (void)drainMainQueue {
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        drained = YES;
    });
    [self runMainLoopUntil:&drained timeout:1];
}

- (void)testAllocatedFileReportsMaterializedAtOne {
    NSURL *url = [self URLNamed:@"allocated.bin"];
    XCTAssertTrue([self writeAllocatedBytesToURL:url length:64 * 1024]);
    __block BOOL reported = NO;
    __block DownloadAllocatedSizeSource *source = nil;
    source = [[DownloadAllocatedSizeSource alloc] initWithURL:url
            handler:^(float fraction, BOOL materialized, BOOL dataless,
                      long long allocatedBytes, long long logicalBytes) {
        XCTAssertEqualWithAccuracy(fraction, 1.0f, 0.0001f);
        XCTAssertTrue(materialized);
        XCTAssertFalse(dataless);
        XCTAssertGreaterThanOrEqual(allocatedBytes, logicalBytes);
        reported = YES;
        [source cancel];
    }];
    [_sources addObject:source];
    [source start];
    [self runMainLoopUntil:&reported timeout:3];
}

- (void)testSparseFileReportsPartialAllocationWithoutClaimingMaterialized {
    NSURL *url = [self URLNamed:@"sparse.bin"];
    int descriptor = open(url.fileSystemRepresentation,
                          O_CREAT | O_TRUNC | O_RDWR, 0600);
    XCTAssertGreaterThanOrEqual(descriptor, 0);
    XCTAssertEqual(ftruncate(descriptor, 64 * 1024 * 1024), 0);
    unsigned char byte = 1;
    XCTAssertEqual(pwrite(descriptor, &byte, sizeof(byte), 0), (ssize_t)sizeof(byte));
    XCTAssertEqual(close(descriptor), 0);

    __block BOOL reported = NO;
    __block DownloadAllocatedSizeSource *source = nil;
    source = [[DownloadAllocatedSizeSource alloc] initWithURL:url
            handler:^(float fraction, BOOL materialized, BOOL dataless,
                      long long allocatedBytes, long long logicalBytes) {
        XCTAssertGreaterThan(fraction, 0.0f);
        XCTAssertLessThan(fraction, 1.0f);
        XCTAssertFalse(materialized);
        XCTAssertFalse(dataless);
        XCTAssertGreaterThan(allocatedBytes, 0);
        XCTAssertLessThan(allocatedBytes, logicalBytes);
        reported = YES;
        [source cancel];
    }];
    [_sources addObject:source];
    [source start];
    [self runMainLoopUntil:&reported timeout:3];
}

- (void)testEmptyFilePublishesNoMisleadingFraction {
    NSURL *url = [self URLNamed:@"empty.bin"];
    XCTAssertTrue([NSData.data writeToURL:url atomically:YES]);
    XCTestExpectation *silent = [self expectationWithDescription:@"no empty sample"];
    silent.inverted = YES;
    DownloadAllocatedSizeSource *source = [[DownloadAllocatedSizeSource alloc]
            initWithURL:url handler:^(float fraction, BOOL materialized, BOOL dataless,
                                      long long allocatedBytes, long long logicalBytes) {
        [silent fulfill];
    }];
    [_sources addObject:source];
    [source start];
    [self waitForExpectations:@[silent] timeout:0.4];
}

- (void)testNonUbiquitousFileNeverActivatesICloudQuery {
    NSURL *url = [self URLNamed:@"ordinary.bin"];
    XCTAssertTrue([self writeAllocatedBytesToURL:url length:4096]);
    __block NSUInteger deliveries = 0;
    __block NSUInteger queriesConstructed = 0;
    DownloadICloudProgressSource *source = [[DownloadICloudProgressSource alloc]
            initWithURL:url handler:^(float fraction) { deliveries++; }
            queryFactory:^NSMetadataQuery *{
        queriesConstructed++;
        return [[NSMetadataQuery alloc] init];
    } ubiquitousProbe:^BOOL(NSURL *candidate) {
        id ubiquitous = nil;
        return [candidate getResourceValue:&ubiquitous
                                    forKey:NSURLIsUbiquitousItemKey
                                     error:NULL]
                && [ubiquitous boolValue];
    }];
    [source startIfUbiquitous];
    XCTAssertFalse(source.isActive);
    XCTAssertEqual(deliveries, 0u);
    XCTAssertEqual(queriesConstructed, 0u);
    [source cancel];
}

- (void)testProductionICloudProbeRejectsOrdinaryFile {
    NSURL *url = [self URLNamed:@"ordinary-production.bin"];
    XCTAssertTrue([self writeAllocatedBytesToURL:url length:4096]);
    DownloadICloudProgressSource *source = [[DownloadICloudProgressSource alloc]
            initWithURL:url handler:^(float fraction) {
        XCTFail(@"ordinary file must not publish iCloud progress");
    }];
    [_otherSources addObject:source];
    [source startIfUbiquitous];
    XCTAssertFalse(source.isActive);
}

- (void)testICloudQueryConfiguresFiltersNormalizesUpdatesAndCancels {
    NSURL *target = [self URLNamed:@"folder/../wanted.mp3"];
    NSURL *exact = target.URLByStandardizingPath;
    NSURL *sameNameElsewhere = [self URLNamed:@"elsewhere/wanted.mp3"];
    FakeDownloadMetadataItem *wrong = [[FakeDownloadMetadataItem alloc]
            initWithURL:sameNameElsewhere percent:@90.0];
    FakeDownloadMetadataItem *wanted = [[FakeDownloadMetadataItem alloc]
            initWithURL:exact percent:@37.5];
    FakeDownloadMetadataQuery *query = [[FakeDownloadMetadataQuery alloc] init];
    query.items = @[wrong, wanted];

    __block NSUInteger probes = 0;
    __block NSUInteger factories = 0;
    NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
    DownloadICloudProgressSource *source = [[DownloadICloudProgressSource alloc]
            initWithURL:target handler:^(float fraction) {
        [fractions addObject:@(fraction)];
    } queryFactory:^NSMetadataQuery *{
        factories++;
        return query;
    } ubiquitousProbe:^BOOL(NSURL *candidate) {
        probes++;
        XCTAssertEqualObjects(candidate, target);
        return YES;
    }];
    [_otherSources addObject:source];

    [source startIfUbiquitous];
    [source startIfUbiquitous];
    XCTAssertEqual(probes, 1u);
    XCTAssertEqual(factories, 1u);
    XCTAssertEqual(query.startCount, 1u);
    XCTAssertEqualObjects(query.searchScopes,
            (@[NSMetadataQueryUbiquitousDataScope,
               NSMetadataQueryUbiquitousDocumentsScope,
               NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]));
    XCTAssertTrue([query.predicate evaluateWithObject:@{
        NSMetadataItemFSNameKey: @"wanted.mp3"
    }]);
    XCTAssertFalse([query.predicate evaluateWithObject:@{
        NSMetadataItemFSNameKey: @"other.mp3"
    }]);

    [NSNotificationCenter.defaultCenter
            postNotificationName:NSMetadataQueryDidFinishGatheringNotification
                          object:query];
    XCTAssertTrue(source.isActive);
    XCTAssertEqualObjects(fractions, (@[@0.375f]));
    XCTAssertEqual(query.disableCount, 1u);
    XCTAssertEqual(query.enableCount, 1u);

    wanted.percent = @82.25;
    [NSNotificationCenter.defaultCenter
            postNotificationName:NSMetadataQueryDidUpdateNotification object:query];
    XCTAssertEqualObjects(fractions, (@[@0.375f, @0.8225f]));
    XCTAssertEqual(query.disableCount, 2u);
    XCTAssertEqual(query.enableCount, 2u);

    [source cancel];
    XCTAssertFalse(source.isActive);
    XCTAssertEqual(query.stopCount, 1u);
    [NSNotificationCenter.defaultCenter
            postNotificationName:NSMetadataQueryDidUpdateNotification object:query];
    XCTAssertEqual(query.disableCount, 2u);
    XCTAssertEqualObjects(fractions, (@[@0.375f, @0.8225f]));
}

- (void)testICloudFinishedGatheringWithoutExactMatchStopsAsPollOnly {
    NSURL *target = [self URLNamed:@"wanted.mp3"];
    FakeDownloadMetadataQuery *query = [[FakeDownloadMetadataQuery alloc] init];
    query.items = @[[[FakeDownloadMetadataItem alloc]
            initWithURL:[self URLNamed:@"other/wanted.mp3"] percent:@50]];
    __block NSUInteger deliveries = 0;
    DownloadICloudProgressSource *source = [[DownloadICloudProgressSource alloc]
            initWithURL:target handler:^(float fraction) {
        deliveries++;
    } queryFactory:^NSMetadataQuery *{
        return query;
    } ubiquitousProbe:^BOOL(NSURL *candidate) {
        return YES;
    }];
    [_otherSources addObject:source];

    [source startIfUbiquitous];
    [NSNotificationCenter.defaultCenter
            postNotificationName:NSMetadataQueryDidFinishGatheringNotification
                          object:query];
    XCTAssertFalse(source.isActive);
    XCTAssertEqual(deliveries, 0u);
    XCTAssertEqual(query.disableCount, 1u);
    XCTAssertEqual(query.enableCount, 1u);
    XCTAssertEqual(query.stopCount, 1u);

    [NSNotificationCenter.defaultCenter
            postNotificationName:NSMetadataQueryDidUpdateNotification object:query];
    XCTAssertEqual(query.disableCount, 1u);
    [source startIfUbiquitous];
    XCTAssertEqual(query.startCount, 1u);
}

- (void)testICloudExactItemWithoutPercentageStaysObservedButInactive {
    NSURL *target = [self URLNamed:@"wanted.mp3"];
    FakeDownloadMetadataQuery *query = [[FakeDownloadMetadataQuery alloc] init];
    query.items = @[[[FakeDownloadMetadataItem alloc]
            initWithURL:target percent:nil]];
    __block NSUInteger deliveries = 0;
    DownloadICloudProgressSource *source = [[DownloadICloudProgressSource alloc]
            initWithURL:target handler:^(float fraction) {
        deliveries++;
    } queryFactory:^NSMetadataQuery *{
        return query;
    } ubiquitousProbe:^BOOL(NSURL *candidate) {
        return YES;
    }];
    [_otherSources addObject:source];

    [source startIfUbiquitous];
    [NSNotificationCenter.defaultCenter
            postNotificationName:NSMetadataQueryDidFinishGatheringNotification
                          object:query];
    XCTAssertFalse(source.isActive);
    XCTAssertEqual(deliveries, 0u);
    XCTAssertEqual(query.stopCount, 0u);
    XCTAssertEqual(query.disableCount, 1u);
    XCTAssertEqual(query.enableCount, 1u);
}

- (void)testICloudQueryStartFailureTearsDownOnce {
    FakeDownloadMetadataQuery *query = [[FakeDownloadMetadataQuery alloc] init];
    query.startSucceeds = NO;
    __block NSUInteger factories = 0;
    DownloadICloudProgressSource *source = [[DownloadICloudProgressSource alloc]
            initWithURL:[self URLNamed:@"wanted.mp3"] handler:^(float fraction) {
        XCTFail(@"failed query must not publish");
    } queryFactory:^NSMetadataQuery *{
        factories++;
        return query;
    } ubiquitousProbe:^BOOL(NSURL *candidate) {
        return YES;
    }];
    [_otherSources addObject:source];

    [source startIfUbiquitous];
    [source startIfUbiquitous];
    XCTAssertFalse(source.isActive);
    XCTAssertEqual(factories, 1u);
    XCTAssertEqual(query.startCount, 1u);
    XCTAssertEqual(query.stopCount, 1u);
}

#if TARGET_OS_OSX

- (void)testProductionFileProviderSourceIsInertUntilStarted {
    __weak DownloadFileProviderProgressSource *weakSource = nil;
    @autoreleasepool {
        DownloadFileProviderProgressSource *source =
                [[DownloadFileProviderProgressSource alloc]
                        initWithURL:[self URLNamed:@"wanted.mp3"]
                            handler:^(float fraction) {
            XCTFail(@"an unstarted source must not publish");
        }];
        weakSource = source;
        XCTAssertFalse(source.isActive);
    }
    XCTAssertNil(weakSource);
}

- (void)testFileProviderPublicationDrivesInitialKVOUpdatesAndUnpublish {
    NSURL *target = [self URLNamed:@"wanted.mp3"];
    NSObject *token = [[NSObject alloc] init];
    __block NSUInteger subscriptions = 0;
    __block NSUInteger removals = 0;
    __block NSProgressPublishingHandler publishingHandler = nil;
    NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
    DownloadFileProviderProgressSource *source =
            [[DownloadFileProviderProgressSource alloc]
                    initWithURL:target handler:^(float fraction) {
        [fractions addObject:@(fraction)];
    } subscriber:^id(NSURL *candidate, NSProgressPublishingHandler handler) {
        subscriptions++;
        XCTAssertEqualObjects(candidate, target);
        publishingHandler = [handler copy];
        return token;
    } unsubscriber:^(id subscriberToken) {
        removals++;
        XCTAssertEqual(subscriberToken, token);
    }];
    [_otherSources addObject:source];

    [source start];
    [source start];
    XCTAssertEqual(subscriptions, 1u);
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:100];
    progress.completedUnitCount = 20;
    NSProgressUnpublishingHandler unpublish = publishingHandler(progress);
    [self runMainLoopUntilBlock:^BOOL{
        return source.isActive && fractions.count == 1;
    } timeout:1];
    XCTAssertEqualWithAccuracy(fractions[0].floatValue, 0.2f, 0.0001f);

    progress.completedUnitCount = 60;
    [self runMainLoopUntilBlock:^BOOL{
        return fractions.count == 2;
    } timeout:1];
    XCTAssertEqualWithAccuracy(fractions[1].floatValue, 0.6f, 0.0001f);

    unpublish();
    [self runMainLoopUntilBlock:^BOOL{
        return !source.isActive;
    } timeout:1];
    progress.completedUnitCount = 90;
    [self drainMainQueue];
    XCTAssertEqual(fractions.count, 2u);

    [source cancel];
    [source cancel];
    [source start];
    XCTAssertEqual(removals, 1u);
    XCTAssertEqual(subscriptions, 1u);
}

- (void)testFileProviderReplacementIgnoresStaleKVOAndCancelIsTerminal {
    NSObject *token = [[NSObject alloc] init];
    __block NSUInteger subscriptions = 0;
    __block NSUInteger removals = 0;
    __block NSProgressPublishingHandler publishingHandler = nil;
    NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
    DownloadFileProviderProgressSource *source =
            [[DownloadFileProviderProgressSource alloc]
                    initWithURL:[self URLNamed:@"wanted.mp3"]
                        handler:^(float fraction) {
        [fractions addObject:@(fraction)];
    } subscriber:^id(NSURL *candidate, NSProgressPublishingHandler handler) {
        subscriptions++;
        publishingHandler = [handler copy];
        return token;
    } unsubscriber:^(id subscriberToken) {
        removals++;
        XCTAssertEqual(subscriberToken, token);
    }];
    [_otherSources addObject:source];
    [source start];

    NSProgress *first = [NSProgress progressWithTotalUnitCount:100];
    first.completedUnitCount = 10;
    NSProgressUnpublishingHandler unpublishFirst = publishingHandler(first);
    NSProgress *second = [NSProgress progressWithTotalUnitCount:100];
    second.completedUnitCount = 25;
    NSProgressUnpublishingHandler unpublishSecond = publishingHandler(second);
    [self runMainLoopUntilBlock:^BOOL{
        return source.isActive && fractions.count == 1;
    } timeout:1];
    XCTAssertEqualWithAccuracy(fractions[0].floatValue, 0.25f, 0.0001f);

    unpublishFirst();
    [self drainMainQueue];
    XCTAssertTrue(source.isActive);
    first.completedUnitCount = 70;
    [self drainMainQueue];
    XCTAssertEqual(fractions.count, 1u);

    second.completedUnitCount = 50;
    [self runMainLoopUntilBlock:^BOOL{
        return fractions.count == 2;
    } timeout:1];
    XCTAssertEqualWithAccuracy(fractions[1].floatValue, 0.5f, 0.0001f);

    [source cancel];
    XCTAssertFalse(source.isActive);
    XCTAssertEqual(removals, 1u);
    second.completedUnitCount = 80;
    unpublishSecond();
    NSProgress *late = [NSProgress progressWithTotalUnitCount:100];
    late.completedUnitCount = 90;
    publishingHandler(late);
    [self drainMainQueue];
    XCTAssertEqual(fractions.count, 2u);
    XCTAssertFalse(source.isActive);

    [source cancel];
    [source start];
    XCTAssertEqual(removals, 1u);
    XCTAssertEqual(subscriptions, 1u);
}

#endif

@end

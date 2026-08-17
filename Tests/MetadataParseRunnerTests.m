//
//  MetadataParseRunnerTests.m
//
//  The stage-2 parse ordering: what a row does when the answer is already
//  somewhere, and what the duplicate rows behind it get.
//

#import <XCTest/XCTest.h>

#import <unistd.h>

#import "MetadataParseCoordinator.h"
#import "MetadataParseRunner.h"

// One playlist row. `resolved` stands in for AudioTrackMetadata.parsedOK.
@interface ParseRow : NSObject
@property (nonatomic) BOOL resolved;
@property (nonatomic, copy) NSString *name;
@end

@implementation ParseRow
@end

// The loader's four effects, recorded. Thread-safe throughout: the stress test
// drives it from every core at once, and a counter racing there would report a
// pass that never happened.
@interface ParseRecorder : NSObject <MetadataParseRunnerDelegate>

// The cache identity each row parses under, and the keys an entry exists for.
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *keysByRow;
@property (nonatomic, strong) NSMutableSet *storedKeys;
// Every callback in order, as "verb:row" — the runner's whole observable output.
@property (nonatomic, strong) NSMutableArray<NSString *> *trace;
// Parses that must fail: the row resolves, but nothing is written, so its
// waiters find no entry.
@property (nonatomic, strong) NSMutableSet<NSString *> *failingRows;
// Runs inside a parse, so a test can act while one is in flight.
@property (nonatomic, copy, nullable) void (^duringParse)(ParseRow *row);
// Runs before a cache read, for asserting what is true at that moment.
@property (nonatomic, copy, nullable) void (^beforeServe)(ParseRow *row);
// The same, for the owner's own publish.
@property (nonatomic, copy, nullable) void (^beforePublish)(ParseRow *row);
// Runs after each resolved? answer is read, for landing another lane's result
// in one of the windows between two of them.
@property (nonatomic, copy, nullable) void (^afterResolvedAsk)(ParseRow *row);

@end

@implementation ParseRecorder

- (instancetype)init {
    self = [super init];
    if (self) {
        _keysByRow = [NSMutableDictionary dictionary];
        _storedKeys = [NSMutableSet set];
        _trace = [NSMutableArray array];
        _failingRows = [NSMutableSet set];
    }
    return self;
}

- (void)record:(NSString *)verb row:(ParseRow *)row {
    @synchronized (self) {
        [_trace addObject:[NSString stringWithFormat:@"%@:%@", verb, row.name]];
    }
}

- (NSArray<NSString *> *)traceSnapshot {
    @synchronized (self) {
        return [_trace copy];
    }
}

- (NSUInteger)countOf:(NSString *)verb row:(ParseRow *)row {
    NSString *entry = [NSString stringWithFormat:@"%@:%@", verb, row.name];
    NSUInteger count = 0;
    for (NSString *recorded in self.traceSnapshot) {
        if ([recorded isEqualToString:entry]) {
            count++;
        }
    }
    return count;
}

- (NSUInteger)countOfVerb:(NSString *)verb {
    NSString *prefix = [verb stringByAppendingString:@":"];
    NSUInteger count = 0;
    for (NSString *recorded in self.traceSnapshot) {
        if ([recorded hasPrefix:prefix]) {
            count++;
        }
    }
    return count;
}

- (id)keyForRow:(ParseRow *)row {
    @synchronized (self) {
        return _keysByRow[row.name];
    }
}

#pragma mark - MetadataParseRunnerDelegate

- (BOOL)parseRunnerIsResolved:(ParseRow *)row {
    [self record:@"resolved?" row:row];
    BOOL resolved = row.resolved;
    if (self.afterResolvedAsk) {
        self.afterResolvedAsk(row);
    }
    return resolved;
}

- (BOOL)parseRunnerServeFromCache:(ParseRow *)row {
    if (self.beforeServe) {
        self.beforeServe(row);
    }
    [self record:@"serve" row:row];
    BOOL hit;
    @synchronized (self) {
        hit = [_storedKeys containsObject:_keysByRow[row.name]];
    }
    if (hit) {
        row.resolved = YES;
        [self record:@"published" row:row];
    }
    return hit;
}

- (void)parseRunnerReadAndCache:(ParseRow *)row {
    [self record:@"parse" row:row];
    if (self.duringParse) {
        self.duringParse(row);
    }
    row.resolved = YES;
    // A failed parse is never cached: it would shadow the real tags.
    @synchronized (self) {
        if (![_failingRows containsObject:row.name]) {
            [_storedKeys addObject:_keysByRow[row.name]];
        }
    }
}

- (void)parseRunnerPublish:(ParseRow *)row {
    if (self.beforePublish) {
        self.beforePublish(row);
    }
    [self record:@"published" row:row];
}

@end

@interface MetadataParseRunnerTests : XCTestCase
@end

@implementation MetadataParseRunnerTests {
    MetadataParseCoordinator *_coordinator;
    ParseRecorder *_recorder;
    MetadataParseRunner *_runner;
}

- (void)setUp {
    [super setUp];
    _coordinator = [MetadataParseCoordinator new];
    _recorder = [ParseRecorder new];
    _runner = [[MetadataParseRunner alloc] initWithCoordinator:_coordinator delegate:_recorder];
}

// Rows named distinctly but sharing one cache identity are the duplicate-row
// case: the same file on several playlist rows.
- (ParseRow *)rowNamed:(NSString *)name key:(NSString *)key {
    ParseRow *row = [ParseRow new];
    row.name = name;
    @synchronized (_recorder) {
        _recorder.keysByRow[name] = key;
    }
    return row;
}

- (void)run:(ParseRow *)row {
    [_runner runForParticipant:row key:[_recorder keyForRow:row]];
}

#pragma mark - The single row

- (void)testAMissParsesAndPublishesOnce {
    ParseRow *row = [self rowNamed:@"a" key:@"/song.flac"];

    [self run:row];

    XCTAssertEqualObjects(_recorder.traceSnapshot,
                          (@[@"resolved?:a", @"resolved?:a", @"serve:a", @"parse:a", @"published:a"]));
    XCTAssertTrue(row.resolved);
}

- (void)testAnAlreadyResolvedRowIsNotEvenClaimed {
    ParseRow *row = [self rowNamed:@"a" key:@"/song.flac"];
    row.resolved = YES;

    [self run:row];

    XCTAssertEqualObjects(_recorder.traceSnapshot, (@[@"resolved?:a"]));
    // Nothing was claimed, so the key is free for the next row that wants it.
    XCTAssertTrue([_coordinator claimParseForKey:@"/song.flac" participant:row].isOwner);
}

// The c71b81f fix. A different row for the same file finished while this op
// sat queued and released its claim before this one took it, so the claim
// cannot cover it — only the read under the claim can.
- (void)testAnEntryLeftByAnEarlierRowIsReadRatherThanReparsed {
    ParseRow *first = [self rowNamed:@"first" key:@"/song.flac"];
    ParseRow *second = [self rowNamed:@"second" key:@"/song.flac"];
    [self run:first];
    XCTAssertEqual([_recorder countOf:@"parse" row:first], 1u);

    [self run:second];

    XCTAssertEqual([_recorder countOf:@"parse" row:second], 0u);
    XCTAssertEqual([_recorder countOf:@"serve" row:second], 1u);
    XCTAssertEqual([_recorder countOf:@"published" row:second], 1u);
    XCTAssertTrue(second.resolved);
}

// The same window, resolved the other way: the priority lane published onto
// this exact row between the entry check and the claim. Nothing to read,
// nothing to parse — and the claim must still be released.
- (void)testARowResolvedUnderItsOwnClaimSkipsBothTheReadAndTheParse {
    ParseRow *row = [self rowNamed:@"a" key:@"/song.flac"];
    __block NSUInteger asks = 0;
    _recorder.afterResolvedAsk = ^(ParseRow *asked) {
        if (++asks == 1) {
            asked.resolved = YES;
        }
    };

    [self run:row];

    XCTAssertEqual([_recorder countOfVerb:@"serve"], 0u);
    XCTAssertEqual([_recorder countOfVerb:@"parse"], 0u);
    XCTAssertEqual(asks, 2u);
    XCTAssertTrue([_coordinator claimParseForKey:@"/song.flac" participant:[NSObject new]].isOwner);
}

- (void)testAFailedParsePublishesTheFallbackAndCachesNothing {
    ParseRow *row = [self rowNamed:@"a" key:@"/song.flac"];
    [_recorder.failingRows addObject:@"a"];

    [self run:row];

    XCTAssertEqual([_recorder countOf:@"parse" row:row], 1u);
    XCTAssertEqual([_recorder countOf:@"published" row:row], 1u);
    // A later row for the same file finds no entry and parses for itself,
    // rather than inheriting a cached failure.
    ParseRow *later = [self rowNamed:@"later" key:@"/song.flac"];
    [self run:later];
    XCTAssertEqual([_recorder countOf:@"parse" row:later], 1u);
}

- (void)testAnUncoordinatedRowStillParses {
    ParseRow *row = [self rowNamed:@"a" key:@"/song.flac"];

    [_runner runForParticipant:row key:nil];

    XCTAssertEqual([_recorder countOf:@"parse" row:row], 1u);
    XCTAssertEqual([_recorder countOf:@"published" row:row], 1u);
}

- (void)testADepartedDelegateStopsTheRunnerWithoutClaiming {
    MetadataParseRunner *runner;
    @autoreleasepool {
        ParseRecorder *recorder = [ParseRecorder new];
        runner = [[MetadataParseRunner alloc] initWithCoordinator:_coordinator delegate:recorder];
        recorder = nil;
    }
    ParseRow *row = [self rowNamed:@"a" key:@"/song.flac"];

    [runner runForParticipant:row key:@"/song.flac"];

    XCTAssertEqualObjects(_recorder.traceSnapshot, @[]);
    // No claim was taken, so a live runner can still do the work.
    [self run:row];
    XCTAssertEqual([_recorder countOf:@"parse" row:row], 1u);
}

#pragma mark - Duplicate rows

- (void)testWaitersAreServedFromTheEntryTheHolderWroteRatherThanReparsing {
    ParseRow *holder = [self rowNamed:@"holder" key:@"/song.flac"];
    ParseRow *firstWaiter = [self rowNamed:@"first" key:@"/song.flac"];
    ParseRow *secondWaiter = [self rowNamed:@"second" key:@"/song.flac"];
    // Both duplicates reach their parse op while the holder's is in flight.
    __weak __typeof(self) weakSelf = self;
    _recorder.duringParse = ^(ParseRow *row) {
        [weakSelf run:firstWaiter];
        [weakSelf run:secondWaiter];
    };

    [self run:holder];

    XCTAssertEqual([_recorder countOfVerb:@"parse"], 1u);
    for (ParseRow *waiter in @[firstWaiter, secondWaiter]) {
        XCTAssertEqual([_recorder countOf:@"parse" row:waiter], 0u, @"%@", waiter.name);
        XCTAssertEqual([_recorder countOf:@"serve" row:waiter], 1u, @"%@", waiter.name);
        XCTAssertEqual([_recorder countOf:@"published" row:waiter], 1u, @"%@", waiter.name);
        XCTAssertTrue(waiter.resolved, @"%@", waiter.name);
    }
}

// The second c71b81f fix. A re-drop's stage-1 sweep can serve a waiter while
// the parse it waited on still blocks; republishing an equivalent instance
// costs the receiver a redundant delivery and, for the current row, a second
// full-resolution art decode.
- (void)testAWaiterAlreadyServedElsewhereIsLeftAlone {
    ParseRow *holder = [self rowNamed:@"holder" key:@"/song.flac"];
    ParseRow *served = [self rowNamed:@"served" key:@"/song.flac"];
    ParseRow *bare = [self rowNamed:@"bare" key:@"/song.flac"];
    __weak __typeof(self) weakSelf = self;
    _recorder.duringParse = ^(ParseRow *row) {
        [weakSelf run:served];
        [weakSelf run:bare];
        // The sweep lands on one of them mid-parse.
        served.resolved = YES;
    };

    [self run:holder];

    XCTAssertEqual([_recorder countOf:@"serve" row:served], 0u);
    XCTAssertEqual([_recorder countOf:@"published" row:served], 0u);
    XCTAssertEqual([_recorder countOf:@"serve" row:bare], 1u);
    XCTAssertEqual([_recorder countOf:@"published" row:bare], 1u);
}

// The claim must be gone once the parse itself is done: the publishes that
// follow are pure delivery, and holding it across them makes every other row
// of the file wait for work that is not the parse. This is the whole reason
// the protocol splits the parse from its publish.
- (void)testTheClaimIsReleasedBeforeTheParseIsPublishedOrWaitersAreServed {
    ParseRow *holder = [self rowNamed:@"holder" key:@"/song.flac"];
    ParseRow *waiter = [self rowNamed:@"waiter" key:@"/song.flac"];
    __weak __typeof(self) weakSelf = self;
    _recorder.duringParse = ^(ParseRow *row) { [weakSelf run:waiter]; };
    MetadataParseCoordinator *coordinator = _coordinator;
    __block NSUInteger probes = 0;
    __block NSUInteger held = 0;
    void (^probe)(void) = ^{
        MetadataParseClaim *claim = [coordinator claimParseForKey:@"/song.flac"
                                                      participant:[NSObject new]];
        probes++;
        held += claim.isOwner ? 0 : 1;
        [coordinator completeClaim:claim];
    };
    _recorder.beforePublish = ^(ParseRow *row) { probe(); };
    _recorder.beforeServe = ^(ParseRow *row) {
        // Not the holder's own pre-parse read, which legitimately holds it.
        if (row == waiter) {
            probe();
        }
    };

    [self run:holder];

    XCTAssertEqual(probes, 2u);
    XCTAssertEqual(held, 0u);
}

- (void)testAFailedHolderLeavesItsWaitersWithTheFallbackAndNoRetryStorm {
    ParseRow *holder = [self rowNamed:@"holder" key:@"/song.flac"];
    ParseRow *waiter = [self rowNamed:@"waiter" key:@"/song.flac"];
    [_recorder.failingRows addObject:@"holder"];
    __weak __typeof(self) weakSelf = self;
    _recorder.duringParse = ^(ParseRow *row) { [weakSelf run:waiter]; };

    [self run:holder];

    // One read each, missing, and no second parse anywhere: the file is
    // unreadable for every row of it, and rows must not re-queue each other.
    XCTAssertEqual([_recorder countOfVerb:@"parse"], 1u);
    XCTAssertEqual([_recorder countOf:@"serve" row:waiter], 1u);
    XCTAssertEqual([_recorder countOf:@"published" row:waiter], 0u);
    XCTAssertFalse(waiter.resolved);
}

- (void)testRowsForDifferentFilesDoNotWaitOnEachOther {
    ParseRow *first = [self rowNamed:@"first" key:@"/one.flac"];
    ParseRow *second = [self rowNamed:@"second" key:@"/two.flac"];
    __weak __typeof(self) weakSelf = self;
    _recorder.duringParse = ^(ParseRow *row) {
        if (row == first) {
            [weakSelf run:second];
        }
    };

    [self run:first];

    XCTAssertEqual([_recorder countOf:@"parse" row:first], 1u);
    XCTAssertEqual([_recorder countOf:@"parse" row:second], 1u);
}

#pragma mark - Contention

// The real shape of a duplicate-heavy drop: every row of one file reaching its
// parse op at once, on four workers, some before the holder settles and some
// after. The file must be parsed exactly once however the threads interleave,
// every row must end up with metadata, and no row may be published twice.
- (void)testConcurrentRowsForOneFileParseItExactlyOnce {
    static const NSUInteger kRounds = 40;
    static const NSUInteger kRows = 32;

    for (NSUInteger round = 0; round < kRounds; round++) {
        @autoreleasepool {
            _coordinator = [MetadataParseCoordinator new];
            _recorder = [ParseRecorder new];
            _runner = [[MetadataParseRunner alloc] initWithCoordinator:_coordinator delegate:_recorder];
            // Widen the window the late claimers land in: without the read
            // under the claim, a row arriving after the holder released it
            // parses the file a second time.
            _recorder.duringParse = ^(ParseRow *row) { usleep(200); };

            NSMutableArray<ParseRow *> *rows = [NSMutableArray arrayWithCapacity:kRows];
            for (NSUInteger i = 0; i < kRows; i++) {
                [rows addObject:[self rowNamed:[NSString stringWithFormat:@"row%lu", (unsigned long)i]
                                           key:@"/song.flac"]];
            }

            dispatch_apply(kRows, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
                [self run:rows[index]];
            });

            XCTAssertEqual([_recorder countOfVerb:@"parse"], 1u, @"round %lu", (unsigned long)round);
            for (ParseRow *row in rows) {
                XCTAssertTrue(row.resolved, @"round %lu, %@", (unsigned long)round, row.name);
                XCTAssertEqual([_recorder countOf:@"published" row:row], 1u,
                               @"round %lu, %@", (unsigned long)round, row.name);
            }
        }
    }
}

// The same fan-out over several files at once, which is what a folder of
// duplicates actually is. Each file is parsed once and no row is left bare.
- (void)testConcurrentRowsAcrossFilesParseEachFileOnce {
    static const NSUInteger kRounds = 20;
    static const NSUInteger kFiles = 8;
    static const NSUInteger kRowsPerFile = 6;

    for (NSUInteger round = 0; round < kRounds; round++) {
        @autoreleasepool {
            _coordinator = [MetadataParseCoordinator new];
            _recorder = [ParseRecorder new];
            _runner = [[MetadataParseRunner alloc] initWithCoordinator:_coordinator delegate:_recorder];
            _recorder.duringParse = ^(ParseRow *row) { usleep(100); };

            NSMutableArray<ParseRow *> *rows = [NSMutableArray array];
            for (NSUInteger file = 0; file < kFiles; file++) {
                for (NSUInteger copy = 0; copy < kRowsPerFile; copy++) {
                    NSString *name = [NSString stringWithFormat:@"f%lu-r%lu",
                                                                (unsigned long)file, (unsigned long)copy];
                    NSString *key = [NSString stringWithFormat:@"/song%lu.flac", (unsigned long)file];
                    [rows addObject:[self rowNamed:name key:key]];
                }
            }

            dispatch_apply(rows.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
                [self run:rows[index]];
            });

            XCTAssertEqual([_recorder countOfVerb:@"parse"], kFiles, @"round %lu", (unsigned long)round);
            for (ParseRow *row in rows) {
                XCTAssertTrue(row.resolved, @"round %lu, %@", (unsigned long)round, row.name);
                XCTAssertEqual([_recorder countOf:@"published" row:row], 1u,
                               @"round %lu, %@", (unsigned long)round, row.name);
            }
        }
    }
}

@end

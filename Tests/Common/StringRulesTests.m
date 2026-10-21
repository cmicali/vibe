//
// The strings a library's codes and identifiers read as: the play failure's
// status line, the link failure's message, and the waveform styles' names.
//

#import <XCTest/XCTest.h>

#import "StringRules.h"
#import "WaveformRendererRegistry.h"

@interface StringRulesTests : XCTestCase
@end

@implementation StringRulesTests

static NSError *VibeErr(NSString *domain, NSInteger code) {
    return [NSError errorWithDomain:domain code:code userInfo:nil];
}

static NSError *LinkError(VibeLinkError code, NSDictionary *info) {
    return [NSError errorWithDomain:VibeLinkErrorDomain code:code userInfo:info];
}

#pragma mark - The play failure's line

- (void)testEachCodeMapsToItsOwnLine {
    NSArray<NSNumber *> *codes = @[@(VibeAudioErrorFileOpenTimedOut),
                                   @(VibeAudioErrorFileOpenFailed),
                                   @(VibeAudioErrorEngineStartFailed),
                                   @(VibeAudioErrorDeviceUnavailable),
                                   @(VibeAudioErrorDeviceInUse),
                                   @(VibeAudioErrorConnectionLost)];
    NSMutableSet<NSString *> *lines = [NSMutableSet set];
    for (NSNumber *code in codes) {
        NSString *line = VibeStatusForPlayError(VibeErr(kVibeAudioErrorDomain, code.integerValue));
        XCTAssertGreaterThan(line.length, 0u);
        XCTAssertNotEqualObjects(line, VibeStatusForPlayError(VibeErr(@"other.domain", 1)),
                                 @"a mapped code must not fall through to the generic line");
        [lines addObject:line];
    }
    XCTAssertEqual(lines.count, codes.count, @"the mapped codes must not share a line");
}

- (void)testAnUnderlyingErrorOfOursNamesTheCause {
    // A refused start reaches the shell wrapped in the caller's "could not resume".
    NSError *inUse = VibeErr(kVibeAudioErrorDomain, VibeAudioErrorDeviceInUse);
    NSError *wrapped = [NSError errorWithDomain:kVibeAudioErrorDomain code:VibeAudioErrorEngineStartFailed
                                       userInfo:@{NSUnderlyingErrorKey: inUse}];
    XCTAssertEqualObjects(VibeStatusForPlayError(wrapped), VibeStatusForPlayError(inUse));
    NSError *hal = [NSError errorWithDomain:kVibeAudioErrorDomain code:VibeAudioErrorEngineStartFailed
                                   userInfo:@{NSUnderlyingErrorKey: VibeErr(NSOSStatusErrorDomain, -10851)}];
    XCTAssertEqualObjects(VibeStatusForPlayError(hal),
                          VibeStatusForPlayError(VibeErr(kVibeAudioErrorDomain, VibeAudioErrorEngineStartFailed)),
                          @"a foreign underlying error leaves the outer code's line");
}

- (void)testNotPlayingFallsThroughToGeneric {
    // The shell drops it as benign before asking for a line.
    XCTAssertEqualObjects(VibeStatusForPlayError(VibeErr(kVibeAudioErrorDomain,
                                                         VibeAudioErrorNotPlaying)),
                          VibeStatusForPlayError(VibeErr(@"other.domain", 1)));
}

- (void)testUnknownCodeInOurDomainIsGeneric {
    XCTAssertEqualObjects(VibeStatusForPlayError(VibeErr(kVibeAudioErrorDomain, 9999)),
                          VibeStatusForPlayError(VibeErr(@"other.domain", 1)));
}

- (void)testForeignDomainSharingACodeIsGeneric {
    // NSPOSIXErrorDomain code 1 collides numerically with VibeAudioErrorFileOpenFailed.
    XCTAssertEqualObjects(VibeStatusForPlayError(VibeErr(NSPOSIXErrorDomain,
                                                         VibeAudioErrorFileOpenFailed)),
                          VibeStatusForPlayError(VibeErr(@"other.domain", 1)));
}

// NSError refuses a nil domain at construction, so a nil domain reaches the
// mapping only as a message to a nil error.
- (void)testNilDomainIsGenericRatherThanACrash {
    NSString *generic = VibeStatusForPlayError(VibeErr(@"other.domain", VibeAudioErrorFileOpenFailed));
    XCTAssertEqualObjects(VibeStatusForPlayError((NSError *_Nonnull)nil), generic);
    XCTAssertEqualObjects(VibeStatusForPlayError(VibeErr(@"", VibeAudioErrorFileOpenFailed)), generic,
                          @"an empty domain is not ours, whatever its code");
}

#pragma mark - The link failure's message

- (void)testEachFailureShowsItsOwnString {
    NSDictionary<NSNumber *, NSArray<NSString *> *> *expected = @{
        @(VibeLinkErrorInvalid): @[STR_LINK_ERROR_INVALID, STR_LINK_STATUS_INVALID],
        @(VibeLinkErrorInsecure): @[STR_LINK_ERROR_INSECURE, STR_LINK_STATUS_INSECURE],
        @(VibeLinkErrorUnreachable): @[STR_LINK_ERROR_UNREACHABLE, STR_LINK_STATUS_UNREACHABLE],
        @(VibeLinkErrorLocalNetwork): @[STR_LINK_ERROR_LOCAL_NETWORK, STR_LINK_STATUS_LOCAL_NETWORK],
        @(VibeLinkErrorNotFound): @[STR_LINK_ERROR_NOT_FOUND, STR_LINK_STATUS_NOT_FOUND],
        @(VibeLinkErrorDenied): @[STR_LINK_ERROR_DENIED, STR_LINK_STATUS_DENIED],
        @(VibeLinkErrorNotAudio): @[STR_LINK_ERROR_NOT_AUDIO, STR_LINK_STATUS_NOT_AUDIO],
        @(VibeLinkErrorNoSize): @[STR_LINK_ERROR_NO_SIZE, STR_LINK_STATUS_NO_SIZE],
        @(VibeLinkErrorLiveStream): @[STR_LINK_ERROR_LIVE_STREAM, STR_LINK_STATUS_LIVE_STREAM],
        @(VibeLinkErrorICloudPrivate): @[STR_LINK_ERROR_ICLOUD_PRIVATE, STR_LINK_STATUS_ICLOUD_PRIVATE],
        @(VibeLinkErrorICloudFolder): @[STR_LINK_ERROR_ICLOUD_FOLDER, STR_LINK_STATUS_ICLOUD_FOLDER],
        @(VibeLinkErrorICloudUnreadable): @[STR_LINK_ERROR_ICLOUD_UNREADABLE, STR_LINK_STATUS_ICLOUD_UNREADABLE],
    };
    for (NSNumber *code in expected) {
        NSError *error = LinkError(code.integerValue, nil);
        XCTAssertEqualObjects(VibeLinkMessageForError(error, NO), expected[code][0], @"%@", code);
        XCTAssertEqualObjects(VibeLinkMessageForError(error, YES), expected[code][1], @"%@", code);
    }
    for (NSUInteger brief = 0; brief < 2; brief++) {
        NSMutableSet<NSString *> *distinct = [NSMutableSet set];
        for (NSArray<NSString *> *pair in expected.allValues) {
            [distinct addObject:pair[brief]];
        }
        [distinct addObject:brief ? STR_LINK_STATUS_SERVER : STR_LINK_ERROR_SERVER];
        XCTAssertEqual(distinct.count, expected.count + 1, @"no two failures share a string");
    }
}

- (void)testAServerFailureNamesItsStatus {
    NSError *error = LinkError(VibeLinkErrorServer, @{VibeHTTPErrorStatusCodeKey: @503});
    XCTAssertEqualObjects(VibeLinkMessageForError(error, NO),
                          ([NSString stringWithFormat:STR_LINK_ERROR_SERVER, 503L]));
    XCTAssertEqualObjects(VibeLinkMessageForError(error, YES),
                          ([NSString stringWithFormat:STR_LINK_STATUS_SERVER, 503L]));
    XCTAssertTrue([VibeLinkMessageForError(error, NO) containsString:@"503"]);
    XCTAssertTrue([VibeLinkMessageForError(error, YES) containsString:@"503"]);
    XCTAssertEqualObjects(VibeLinkMessageForError(LinkError(VibeLinkErrorServer, nil), NO),
                          ([NSString stringWithFormat:STR_LINK_ERROR_SERVER, 0L]));
    XCTAssertEqualObjects(VibeLinkMessageForError(LinkError(VibeLinkErrorServer, nil), YES),
                          ([NSString stringWithFormat:STR_LINK_STATUS_SERVER, 0L]));
}

- (void)testAnythingElseReadsAsUnreachable {
    NSArray *others = @[
        [NSError errorWithDomain:NSPOSIXErrorDomain code:VibeLinkErrorDenied userInfo:nil],
        [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil],
        LinkError(VibeLinkErrorNone, nil), LinkError(99, nil), LinkError(-1, nil), NSNull.null,
    ];
    for (id other in others) {
        NSError *error = other == NSNull.null ? nil : other;
        XCTAssertEqualObjects(VibeLinkMessageForError(error, NO), STR_LINK_ERROR_UNREACHABLE, @"%@", other);
        XCTAssertEqualObjects(VibeLinkMessageForError(error, YES), STR_LINK_STATUS_UNREACHABLE, @"%@", other);
    }
}

- (void)testACancelShowsNothing {
    XCTAssertNil(VibeLinkMessageForError(LinkError(VibeLinkErrorCancelled, nil), NO));
    XCTAssertNil(VibeLinkMessageForError(LinkError(VibeLinkErrorCancelled, nil), YES));
    NSError *other = [NSError errorWithDomain:NSURLErrorDomain code:VibeLinkErrorCancelled userInfo:nil];
    XCTAssertEqualObjects(VibeLinkMessageForError(other, NO), STR_LINK_ERROR_UNREACHABLE);
    XCTAssertEqualObjects(VibeLinkMessageForError(other, YES), STR_LINK_STATUS_UNREACHABLE);
}

#pragma mark - The waveform styles' names

// The table names every registered style, so a new renderer without a row
// fails here, not in a chooser.
- (void)testEveryRegisteredStyleHasAName {
    for (NSString *identifier in WaveformRendererRegistry.availableIdentifiers) {
        XCTAssertNotEqualObjects(VibeWaveformStyleDisplayName(identifier), identifier, @"%@", identifier);
    }
    XCTAssertEqualObjects(VibeWaveformStyleDisplayName(@"missing-style"), @"missing-style");
    XCTAssertEqualObjects(VibeWaveformStyleDisplayName(@"wiggle_centered"), STR_WAVEFORM_STYLE_WIGGLE);
    XCTAssertEqualObjects(VibeWaveformStyleDisplayName(@"spectrum"), STR_WAVEFORM_STYLE_SPECTRUM);
}

// NSPopUpButton drops an item whose title repeats another's, and the
// chooser's order is by name.
- (void)testTheChoosersListDistinctNamesByName {
    NSArray<NSString *> *styles = VibeWaveformStylesByDisplayName(WaveformRendererRegistry.styleIdentifiers);
    XCTAssertEqual(styles.count, WaveformRendererRegistry.styleIdentifiers.count);
    NSMutableSet<NSString *> *styleNames = [NSMutableSet set];
    NSString *previous = nil;
    for (NSString *style in styles) {
        NSString *name = VibeWaveformStyleDisplayName(style);
        [styleNames addObject:name];
        if (previous) {
            XCTAssertNotEqual([previous localizedStandardCompare:name], NSOrderedDescending, @"%@ before %@", previous, name);
        }
        previous = name;
    }
    XCTAssertEqual(styleNames.count, styles.count);
}

// The Detailed family's types share the style's name, and the Type chooser
// tells them apart.
- (void)testDetailedTypesShareTheStyleNameAndHaveTheirOwnTypeNames {
    NSArray<NSString *> *types = [WaveformRendererRegistry typeIdentifiersForIdentifier:@"detailed"];
    XCTAssertEqual(types.count, 4u);
    NSMutableSet<NSString *> *typeNames = [NSMutableSet set];
    for (NSString *type in types) {
        XCTAssertEqualObjects(VibeWaveformStyleDisplayName(type), STR_WAVEFORM_STYLE_DETAILED);
        [typeNames addObject:VibeWaveformTypeDisplayName(type)];
    }
    XCTAssertEqual(typeNames.count, types.count);
    XCTAssertEqualObjects(VibeWaveformTypeDisplayName(@"detailed"), STR_WAVEFORM_STYLE_DETAILED);
    XCTAssertEqualObjects(VibeWaveformTypeDisplayName(@"basic"), STR_WAVEFORM_STYLE_BASIC);
}

@end

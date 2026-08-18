//
//  AudioLoadingConfigurationDebugTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "AudioLoadingConfiguration+Debug.h"

@interface AudioLoadingConfigurationDebugTests : XCTestCase
@end

@implementation AudioLoadingConfigurationDebugTests

- (AudioLoadingConfiguration *)configurationFrom:(AudioLoadingConfiguration *)base
                                         arguments:(NSArray<NSString *> *)arguments
                                             error:(NSError **)error {
    return [AudioLoadingConfiguration debugConfigurationByApplyingArguments:arguments
                                                            toConfiguration:base
                                                                      error:error];
}

- (void)testEverySafeAndDiagnosticOptionParsesIntoOneSnapshot {
    NSError *error = nil;
    AudioLoadingConfiguration *configuration = [self
            configurationFrom:[AudioLoadingConfiguration productionConfiguration]
            arguments:@[@"background=3", @"local-parses=7", @"prefetch-depth=0",
                        @"interactive=5", @"interactive-pending=8",
                        @"background-pending=13", @"interactive-grace=17.5",
                        @"background-grace=19.5", @"retries=23",
                        @"timeout-baseline=45", @"timeout-silence=30"]
            error:&error];

    XCTAssertNotNil(configuration);
    XCTAssertNil(error);
    VibeAudioLoadingConfigurationValues values = configuration.values;
    XCTAssertEqual(values.maximumBackgroundMaterializations, 3u);
    XCTAssertEqual(values.localMetadataParseConcurrency, 7u);
    XCTAssertEqual(values.prefetchDepth, 0u);
    XCTAssertEqual(values.maximumInteractiveMaterializations, 5u);
    XCTAssertEqual(values.maximumInteractivePendingMaterializations, 8u);
    XCTAssertEqual(values.maximumBackgroundPendingMaterializations, 13u);
    XCTAssertEqualWithAccuracy(values.interactiveAdmissionGrace, 17.5, 0.001);
    XCTAssertEqualWithAccuracy(values.backgroundAdmissionGrace, 19.5, 0.001);
    XCTAssertEqual(values.metadataRetryCount, 23u);
    XCTAssertEqualWithAccuracy(values.openTimeouts.noProgressSeconds, 45, 0.001);
    XCTAssertEqualWithAccuracy(values.openTimeouts.progressSilenceSeconds, 30, 0.001);
}

- (void)testPartialUpdatePreservesUnmentionedValues {
    AudioLoadingConfiguration *base = [AudioLoadingConfiguration productionConfiguration];
    NSError *error = nil;
    AudioLoadingConfiguration *configuration = [self configurationFrom:base
            arguments:@[@"background=2"] error:&error];

    XCTAssertNotNil(configuration);
    XCTAssertEqual(configuration.maximumBackgroundMaterializations, 2u);
    XCTAssertEqual(configuration.localMetadataParseConcurrency,
                   base.localMetadataParseConcurrency);
    XCTAssertEqual(configuration.maximumInteractiveMaterializations,
                   base.maximumInteractiveMaterializations);
    XCTAssertEqualWithAccuracy(configuration.openTimeouts.noProgressSeconds,
                               base.openTimeouts.noProgressSeconds, 0.001);
}

- (void)testDefaultsMayBeFollowedByOverrides {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 4;
    values.localMetadataParseConcurrency = 9;
    NSError *error = nil;
    AudioLoadingConfiguration *changed = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&error];
    AudioLoadingConfiguration *reset = [self configurationFrom:changed
            arguments:@[@"defaults", @"prefetch-depth=0"] error:&error];

    XCTAssertNotNil(reset);
    XCTAssertEqual(reset.maximumBackgroundMaterializations, 1u);
    XCTAssertEqual(reset.localMetadataParseConcurrency, 4u);
    XCTAssertEqual(reset.prefetchDepth, 0u);
}

- (void)testDefaultsAloneRestoresTheEntireProductionSnapshot {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 4;
    values.localMetadataParseConcurrency = 9;
    values.prefetchDepth = 0;
    values.maximumInteractiveMaterializations = 7;
    values.maximumInteractivePendingMaterializations = 10;
    values.maximumBackgroundPendingMaterializations = 12;
    values.interactiveAdmissionGrace = 20;
    values.backgroundAdmissionGrace = 21;
    values.metadataRetryCount = 8;
    values.openTimeouts = VibeAudioOpenTimeoutConfigurationMake(90, 40);
    NSError *error = nil;
    AudioLoadingConfiguration *changed = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&error];
    AudioLoadingConfiguration *reset = [self configurationFrom:changed
            arguments:@[@"defaults"] error:&error];

    XCTAssertNotNil(reset);
    XCTAssertEqualObjects(reset.debugDictionary,
                          AudioLoadingConfiguration.productionConfiguration.debugDictionary);
}

- (void)testMalformedBatchIsRejectedWithoutMutatingTheBase {
    AudioLoadingConfiguration *base = [AudioLoadingConfiguration productionConfiguration];
    NSError *error = nil;
    AudioLoadingConfiguration *configuration = [self configurationFrom:base
            arguments:@[@"background=3", @"local-parses=oops"] error:&error];

    XCTAssertNil(configuration);
    XCTAssertNotNil(error);
    XCTAssertEqual(base.maximumBackgroundMaterializations, 1u);
    XCTAssertEqual(base.localMetadataParseConcurrency, 4u);
}

- (void)testCountParsingRejectsOverflowBeforeConversion {
    NSString *maximum = [NSString stringWithFormat:@"%llu",
            (unsigned long long)NSUIntegerMax];
    NSDecimalNumber *tooLargeNumber = [[NSDecimalNumber decimalNumberWithString:maximum]
            decimalNumberByAdding:NSDecimalNumber.one];
    AudioLoadingConfiguration *base = [AudioLoadingConfiguration productionConfiguration];
    NSError *error = nil;
    NSString *maximumOption = [NSString stringWithFormat:@"background=%@", maximum];
    NSString *overflowOption = [NSString stringWithFormat:@"background=%@",
            tooLargeNumber.stringValue];

    AudioLoadingConfiguration *configuration = [self configurationFrom:base
            arguments:@[maximumOption] error:&error];
    XCTAssertNil(configuration);
    XCTAssertEqualObjects(error.userInfo[@"field"], @"maximumBackgroundMaterializations");

    error = nil;
    configuration = [self configurationFrom:base arguments:@[overflowOption] error:&error];
    XCTAssertNil(configuration);
    XCTAssertEqualObjects(error.userInfo[@"option"], overflowOption);
}

- (void)testUnknownEmptyAndOutOfRangeArgumentsAreRejected {
    AudioLoadingConfiguration *base = [AudioLoadingConfiguration productionConfiguration];
    NSArray<NSArray<NSString *> *> *invalid = @[
        @[], @[@"unknown=1"], @[@"background=0"], @[@"prefetch-depth=2"],
        @[@"timeout-baseline=nan"], @[@"defaults=1"], @[@"background=-1"],
        @[@"background=1.5"], @[@"background="], @[@"background"],
        @[@"interactive-pending=1025"],
    ];
    for (NSArray<NSString *> *arguments in invalid) {
        NSError *error = nil;
        XCTAssertNil([self configurationFrom:base arguments:arguments error:&error],
                     @"%@", arguments);
        XCTAssertNotNil(error, @"%@", arguments);
    }
}

- (void)testDiagnosticPendingLimitAcceptsItsUpperBoundary {
    NSError *error = nil;
    AudioLoadingConfiguration *configuration = [self
            configurationFrom:AudioLoadingConfiguration.productionConfiguration
            arguments:@[@"interactive-pending=1024"] error:&error];
    XCTAssertNotNil(configuration);
    XCTAssertNil(error);
    XCTAssertEqual(configuration.maximumInteractivePendingMaterializations, 1024u);
}

- (void)testDictionaryContainsEverySafeAndDiagnosticField {
    NSDictionary *dictionary =
            AudioLoadingConfiguration.productionConfiguration.debugDictionary;
    XCTAssertEqualObjects(dictionary, (@{
        @"safe": @{
            @"background": @1,
            @"localParses": @4,
            @"prefetchDepth": @1,
        },
        @"diagnostic": @{
            @"interactive": @2,
            @"interactivePending": @1,
            @"backgroundPending": @6,
            @"interactiveGrace": @5,
            @"backgroundGrace": @10,
            @"retries": @2,
            @"timeoutBaseline": @60,
            @"timeoutSilence": @60,
        },
    }));
}

- (void)testConsumerDictionaryUsesJSONBooleansForAlignment {
    AudioLoadingConfiguration *production =
            AudioLoadingConfiguration.productionConfiguration;
    NSDictionary *aligned = [AudioLoadingConfiguration
            debugConsumerDictionaryWithMaterialization:production
                                               player:production
                                             metadata:production];
    NSData *alignedData = [NSJSONSerialization dataWithJSONObject:aligned options:0 error:nil];
    NSString *alignedJSON = [[NSString alloc] initWithData:alignedData
                                                  encoding:NSUTF8StringEncoding];
    XCTAssertTrue([alignedJSON containsString:@"\"aligned\":true"]);

    NSError *error = nil;
    AudioLoadingConfiguration *different = [self configurationFrom:production
            arguments:@[@"background=2"] error:&error];
    NSDictionary *misaligned = [AudioLoadingConfiguration
            debugConsumerDictionaryWithMaterialization:production
                                               player:different
                                             metadata:production];
    NSData *misalignedData = [NSJSONSerialization dataWithJSONObject:misaligned
                                                              options:0 error:nil];
    NSString *misalignedJSON = [[NSString alloc] initWithData:misalignedData
                                                     encoding:NSUTF8StringEncoding];
    XCTAssertTrue([misalignedJSON containsString:@"\"aligned\":false"]);
}

@end

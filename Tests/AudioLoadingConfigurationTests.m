//
//  AudioLoadingConfigurationTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "AudioLoadingConfiguration.h"

@interface AudioLoadingConfigurationTests : XCTestCase
@end

@implementation AudioLoadingConfigurationTests

- (void)testProductionConfigurationCarriesTheSharedDefaults {
    AudioLoadingConfiguration *configuration =
            [AudioLoadingConfiguration productionConfiguration];

    XCTAssertEqual(configuration.maximumBackgroundMaterializations, 1u);
    XCTAssertEqual(configuration.localMetadataParseConcurrency, 4u);
    XCTAssertEqual(configuration.prefetchDepth, 1u);
    // Handle-run admission is independent (spec J8); changing foreground
    // transfer concurrency would be a separate policy decision.
    XCTAssertEqual(configuration.maximumInteractiveMaterializations, 3u);
    XCTAssertEqual(configuration.maximumInteractivePendingMaterializations, 1u);
    XCTAssertEqual(configuration.maximumBackgroundPendingMaterializations, 6u);
    XCTAssertEqualWithAccuracy(configuration.interactiveAdmissionGrace, 5.0, 0.001);
    XCTAssertEqualWithAccuracy(configuration.backgroundAdmissionGrace, 10.0, 0.001);
    XCTAssertEqual(configuration.metadataRetryCount, 2u);
    XCTAssertEqualWithAccuracy(configuration.openTimeouts.noProgressSeconds,
                               kVibeAudioOpenDefaultNoProgressSeconds, 0.001);
    XCTAssertEqualWithAccuracy(configuration.openTimeouts.progressSilenceSeconds,
                               kVibeAudioOpenDefaultProgressSilenceSeconds, 0.001);
}

- (void)testConfigurationCopiesAsOneImmutableSnapshot {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 3;
    values.localMetadataParseConcurrency = 7;
    values.prefetchDepth = 0;
    values.maximumInteractiveMaterializations = 5;
    values.maximumInteractivePendingMaterializations = 8;
    values.maximumBackgroundPendingMaterializations = 13;
    values.interactiveAdmissionGrace = 17;
    values.backgroundAdmissionGrace = 19;
    values.metadataRetryCount = 23;
    values.openTimeouts = VibeAudioOpenTimeoutConfigurationMake(45, 30);
    NSError *error = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&error];

    XCTAssertNotNil(configuration);
    XCTAssertNil(error);
    XCTAssertEqual(configuration.maximumBackgroundMaterializations, 3u);
    XCTAssertEqual(configuration.localMetadataParseConcurrency, 7u);
    XCTAssertEqual(configuration.prefetchDepth, 0u);
    XCTAssertEqualWithAccuracy(configuration.openTimeouts.noProgressSeconds, 45, 0.001);
    XCTAssertEqual([configuration copy], configuration);

    VibeAudioLoadingConfigurationValues snapshot = configuration.values;
    XCTAssertEqual(snapshot.maximumBackgroundMaterializations, 3u);
    XCTAssertEqual(snapshot.localMetadataParseConcurrency, 7u);
    XCTAssertEqual(snapshot.prefetchDepth, 0u);
    XCTAssertEqual(snapshot.maximumInteractiveMaterializations, 5u);
    XCTAssertEqual(snapshot.maximumInteractivePendingMaterializations, 8u);
    XCTAssertEqual(snapshot.maximumBackgroundPendingMaterializations, 13u);
    XCTAssertEqualWithAccuracy(snapshot.interactiveAdmissionGrace, 17, 0.001);
    XCTAssertEqualWithAccuracy(snapshot.backgroundAdmissionGrace, 19, 0.001);
    XCTAssertEqual(snapshot.metadataRetryCount, 23u);
    XCTAssertEqualWithAccuracy(snapshot.openTimeouts.noProgressSeconds, 45, 0.001);
    XCTAssertEqualWithAccuracy(snapshot.openTimeouts.progressSilenceSeconds, 30, 0.001);

    values.maximumBackgroundMaterializations = 1;
    values.openTimeouts.noProgressSeconds = 5;
    XCTAssertEqual(configuration.maximumBackgroundMaterializations, 3u);
    XCTAssertEqualWithAccuracy(configuration.openTimeouts.noProgressSeconds, 45, 0.001);
}

- (void)testInvalidValuesAreRejectedRatherThanClamped {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 0;
    NSError *error = nil;
    XCTAssertNil([[AudioLoadingConfiguration alloc] initWithValues:values error:&error]);
    XCTAssertEqualObjects(error.userInfo[@"field"], @"maximumBackgroundMaterializations");

    values = VibeAudioLoadingProductionConfigurationValues();
    values.prefetchDepth = 2;
    error = nil;
    XCTAssertNil([[AudioLoadingConfiguration alloc] initWithValues:values error:&error]);
    XCTAssertEqualObjects(error.userInfo[@"field"], @"prefetchDepth");

    values = VibeAudioLoadingProductionConfigurationValues();
    values.openTimeouts.progressSilenceSeconds = NAN;
    error = nil;
    XCTAssertNil([[AudioLoadingConfiguration alloc] initWithValues:values error:&error]);
    XCTAssertEqualObjects(error.userInfo[@"field"], @"openTimeouts.progressSilenceSeconds");
}

@end

//
//  AudioLoadingConfiguration+Debug.m
//  Vibe
//

#import "AudioLoadingConfiguration+Debug.h"
#import "DebugWireFormat.h"

#if DEBUG

#include <errno.h>
#include <stdlib.h>

static NSError *VibeAudioLoadingArgumentError(NSString *description,
                                              NSString *option) {
    return [NSError errorWithDomain:VibeAudioLoadingConfigurationErrorDomain
                               code:VibeAudioLoadingConfigurationErrorInvalidValue
                           userInfo:@{
        NSLocalizedDescriptionKey: description,
        @"option": option,
    }];
}

static BOOL VibeParseAudioLoadingDuration(NSString *text, double *value) {
    const char *characters = text.UTF8String;
    if (!characters || !characters[0]) {
        return NO;
    }
    errno = 0;
    char *end = NULL;
    double parsed = strtod(characters, &end);
    if (errno == ERANGE || end == characters || !end || end[0] != '\0') {
        return NO;
    }
    *value = parsed;
    return YES;
}

@implementation AudioLoadingConfiguration (Debug)

- (NSDictionary<NSString *, id> *)debugDictionary {
    return @{
        @"safe": @{
            @"background": @(self.maximumBackgroundMaterializations),
            @"localParses": @(self.localMetadataParseConcurrency),
            @"prefetchDepth": @(self.prefetchDepth),
        },
        @"diagnostic": @{
            @"interactive": @(self.maximumInteractiveMaterializations),
            @"interactivePending": @(self.maximumInteractivePendingMaterializations),
            @"backgroundPending": @(self.maximumBackgroundPendingMaterializations),
            @"interactiveGrace": @(self.interactiveAdmissionGrace),
            @"backgroundGrace": @(self.backgroundAdmissionGrace),
            @"retries": @(self.metadataRetryCount),
            @"timeoutBaseline": @(self.openTimeouts.noProgressSeconds),
            @"timeoutSilence": @(self.openTimeouts.progressSilenceSeconds),
        },
    };
}

+ (NSDictionary<NSString *, id> *)debugConsumerDictionaryWithMaterialization:
        (AudioLoadingConfiguration *)materialization
        player:(AudioLoadingConfiguration *)player
        metadata:(AudioLoadingConfiguration *)metadata {
    NSDictionary *materializationJSON = materialization.debugDictionary;
    NSDictionary *playerJSON = player.debugDictionary;
    NSDictionary *metadataJSON = metadata.debugDictionary;
    BOOL aligned = [materializationJSON isEqual:playerJSON]
            && [materializationJSON isEqual:metadataJSON];
    return @{
        @"aligned": @(aligned),
        @"materialization": materializationJSON,
        @"player": playerJSON,
        @"metadata": metadataJSON,
    };
}

+ (instancetype)debugConfigurationByApplyingArguments:(NSArray<NSString *> *)arguments
                                       toConfiguration:(AudioLoadingConfiguration *)configuration
                                                 error:(NSError *__autoreleasing *)error {
    if (!arguments.count) {
        if (error) {
            *error = VibeAudioLoadingArgumentError(
                    @"Expected defaults or at least one key=value option", @"");
        }
        return nil;
    }
    VibeAudioLoadingConfigurationValues values = configuration.values;
    NSUInteger firstOption = 0;
    if ([arguments.firstObject isEqualToString:@"defaults"]) {
        values = VibeAudioLoadingProductionConfigurationValues();
        firstOption = 1;
    }
    for (NSUInteger index = firstOption; index < arguments.count; index++) {
        NSString *option = arguments[index];
        NSRange separator = [option rangeOfString:@"="];
        if (separator.location == NSNotFound || separator.location == 0
                || NSMaxRange(separator) == option.length) {
            if (error) {
                *error = VibeAudioLoadingArgumentError(
                        [NSString stringWithFormat:@"Expected key=value, got '%@'", option],
                        option);
            }
            return nil;
        }
        NSString *key = [option substringToIndex:separator.location];
        NSString *text = [option substringFromIndex:NSMaxRange(separator)];
        NSUInteger count = 0;
        double seconds = 0;
        BOOL recognized = YES;
        BOOL parsed = YES;
        if ([key isEqualToString:@"background"]) {
            parsed = VibeParseNonnegativeInteger(text, &count);
            values.maximumBackgroundMaterializations = count;
        }
        else if ([key isEqualToString:@"local-parses"]) {
            parsed = VibeParseNonnegativeInteger(text, &count);
            values.localMetadataParseConcurrency = count;
        }
        else if ([key isEqualToString:@"prefetch-depth"]) {
            parsed = VibeParseNonnegativeInteger(text, &count);
            values.prefetchDepth = count;
        }
        else if ([key isEqualToString:@"interactive"]) {
            parsed = VibeParseNonnegativeInteger(text, &count);
            values.maximumInteractiveMaterializations = count;
        }
        else if ([key isEqualToString:@"interactive-pending"]) {
            parsed = VibeParseNonnegativeInteger(text, &count);
            values.maximumInteractivePendingMaterializations = count;
        }
        else if ([key isEqualToString:@"background-pending"]) {
            parsed = VibeParseNonnegativeInteger(text, &count);
            values.maximumBackgroundPendingMaterializations = count;
        }
        else if ([key isEqualToString:@"interactive-grace"]) {
            parsed = VibeParseAudioLoadingDuration(text, &seconds);
            values.interactiveAdmissionGrace = seconds;
        }
        else if ([key isEqualToString:@"background-grace"]) {
            parsed = VibeParseAudioLoadingDuration(text, &seconds);
            values.backgroundAdmissionGrace = seconds;
        }
        else if ([key isEqualToString:@"retries"]) {
            parsed = VibeParseNonnegativeInteger(text, &count);
            values.metadataRetryCount = count;
        }
        else if ([key isEqualToString:@"timeout-baseline"]) {
            parsed = VibeParseAudioLoadingDuration(text, &seconds);
            values.openTimeouts.noProgressSeconds = seconds;
        }
        else if ([key isEqualToString:@"timeout-silence"]) {
            parsed = VibeParseAudioLoadingDuration(text, &seconds);
            values.openTimeouts.progressSilenceSeconds = seconds;
        }
        else {
            recognized = NO;
        }
        if (!recognized || !parsed) {
            if (error) {
                *error = VibeAudioLoadingArgumentError(
                        [NSString stringWithFormat:
                                @"Unknown or malformed audio-loading option '%@'", option],
                        option);
            }
            return nil;
        }
    }
    return [[self alloc] initWithValues:values error:error];
}

@end

#endif

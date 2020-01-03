//
// Created by Christopher Micali on 12/28/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioDevice.h"
#import "CoreAudioUtil.h"


@implementation AudioDevice {
    NSArray<NSNumber *> *_supportedOutputSampleRates;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _supportedOutputSampleRates = nil;
    }
    return self;
}

- (BOOL)isEqual:(AudioDevice*)object {
    return self.deviceId == object.deviceId;
}

- (NSUInteger)hash {
    return [[NSString stringWithFormat:@"%ld", (long)self.deviceId] hash];
}

- (NSArray<NSNumber *> *)supportedOutputSampleRates {
    if (!_supportedOutputSampleRates) {
        _supportedOutputSampleRates = [CoreAudioUtil supportedSampleRatesForOutputDevice:self.uid];
    }
    return _supportedOutputSampleRates;
}

- (void)setSupportedOutputSampleRates:(NSArray<NSNumber *> *)supportedOutputSampleRates {
    _supportedOutputSampleRates = supportedOutputSampleRates;
}


@end

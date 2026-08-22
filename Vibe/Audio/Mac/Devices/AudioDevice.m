//
//  AudioDevice.m
//  Vibe
//

#import "AudioDevice.h"


@implementation AudioDevice

- (instancetype)initWithName:(NSString *)name
                         uid:(NSString *)uid
                    deviceId:(NSInteger)deviceId
             isSystemDefault:(BOOL)isSystemDefault {
    self = [super init];
    if (self) {
        _name = [name copy];
        _uid = [uid copy];
        _deviceId = deviceId;
        _isSystemDefault = isSystemDefault;
    }
    return self;
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[AudioDevice class]]) return NO;
    return self.deviceId == ((AudioDevice *)object).deviceId;
}

- (NSUInteger)hash {
    return (NSUInteger)self.deviceId;
}

@end

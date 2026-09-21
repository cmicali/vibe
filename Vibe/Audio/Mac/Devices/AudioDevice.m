//
//  AudioDevice.m
//  Vibe
//

#import "AudioDevice.h"


@implementation AudioDevice

- (instancetype)initWithName:(NSString *)name
                         uid:(NSString *)uid
                    deviceId:(NSInteger)deviceId
             isSystemDefault:(BOOL)isSystemDefault
               transportType:(UInt32)transportType {
    return [self initWithName:name uid:uid modelUID:@"" deviceId:deviceId
              isSystemDefault:isSystemDefault transportType:transportType];
}

- (instancetype)initWithName:(NSString *)name
                         uid:(NSString *)uid
                    modelUID:(NSString *)modelUID
                    deviceId:(NSInteger)deviceId
             isSystemDefault:(BOOL)isSystemDefault
               transportType:(UInt32)transportType {
    self = [super init];
    if (self) {
        _name = [name copy];
        _uid = [uid copy];
        _modelUID = [modelUID copy] ?: @"";
        _deviceId = deviceId;
        _isSystemDefault = isSystemDefault;
        _transportType = transportType;
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

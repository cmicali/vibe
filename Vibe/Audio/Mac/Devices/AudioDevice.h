//
//  AudioDevice.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One output device inside AudioDeviceManager's published snapshot. Readonly
// so the snapshot contract is structural: a consumer holding the shared array
// cannot mutate a device out from under the refresh queue or another reader.
@interface AudioDevice : NSObject

- (instancetype)initWithName:(NSString *)name
                         uid:(NSString *)uid
                    deviceId:(NSInteger)deviceId
             isSystemDefault:(BOOL)isSystemDefault;

@property (readonly, copy) NSString *name;
// Empty for a device without a UID, never a shared sentinel; see the
// construction site in AudioDeviceManager.
@property (readonly, copy) NSString *uid;
@property (readonly)       NSInteger deviceId;
@property (readonly)       BOOL isSystemDefault;

@end

NS_ASSUME_NONNULL_END

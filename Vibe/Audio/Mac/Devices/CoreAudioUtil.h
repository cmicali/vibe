//
//  CoreAudioUtil.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

// Raw HAL property accessors, one property read or write per method. Device
// enumeration, AudioDevice model lookup and device-change notifications live
// in AudioDeviceManager.
@interface CoreAudioUtil : NSObject

// Convenience for device-switch paths which must act on the current answer.
// Returns kAudioObjectUnknown for either no default or a read failure; snapshot
// code must use the tri-state form below instead.
+ (AudioDeviceID)systemDefaultOutputDeviceID;

// Each method returns whether the HAL read succeeded separately from its
// answer. A successful default read may answer kAudioObjectUnknown, a
// successful UID read may answer nil when that optional property is absent,
// and a successful channel read may answer NO for an input-only device.
+ (BOOL)readSystemDefaultOutputDeviceID:(AudioDeviceID *)deviceID;
+ (BOOL)readUID:(NSString * _Nullable * _Nonnull)uid
     forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)readName:(NSString * _Nullable * _Nonnull)name
      forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)readHasOutputChannels:(BOOL *)hasOutputChannels
                  forDeviceID:(AudioDeviceID)deviceID;

@end

NS_ASSUME_NONNULL_END

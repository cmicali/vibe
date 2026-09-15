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

// kAudioDevicePropertyTransportType. An optional refinement: the sweep keeps a
// device whose transport is unreadable, as kAudioDeviceTransportTypeUnknown.
+ (BOOL)readTransportType:(UInt32 *)transportType forDeviceID:(AudioDeviceID)deviceID;

// The device's nominal sample rate. A set is applied asynchronously by the
// HAL, so a caller that needs the new rate to be in effect reads it back.
+ (BOOL)readNominalSampleRate:(Float64 *)rate forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)setNominalSampleRate:(Float64)rate forDeviceID:(AudioDeviceID)deviceID;

// The device's first output stream: its id, its current physical format and
// the formats it offers. availableFormats is malloc'd and owned by the caller
// (free() it); it is NULL with count 0 when the stream lists none.
+ (BOOL)readOutputStream:(AudioStreamID *)stream
          physicalFormat:(AudioStreamBasicDescription *)format
        availableFormats:(AudioStreamRangedDescription * _Nullable * _Nonnull)availableFormats
                   count:(UInt32 *)count
             forDeviceID:(AudioDeviceID)deviceID;
// kAudioStreamPropertyPhysicalFormat, which carries rate and depth together.
+ (BOOL)setPhysicalFormat:(AudioStreamBasicDescription)format forStream:(AudioStreamID)stream;

// The HAL's software volume for the device's output ('vmvc'). A device with
// none answers YES with *volume = 1.0: nothing scales its samples.
+ (BOOL)readVirtualMainVolume:(Float32 *)volume forDeviceID:(AudioDeviceID)deviceID;

// kAudioDevicePropertyHogMode: the pid holding exclusive access, -1 when free.
+ (BOOL)readHogOwner:(pid_t *)owner forDeviceID:(AudioDeviceID)deviceID;
// TRAP: setting hog mode ignores the value written and TOGGLES ownership —
// if this process owns it, a set releases it. So this reads first and writes
// only when the owner has to change, which makes it idempotent. YES means the
// device is in the requested state on return.
+ (BOOL)setHogOwnedByThisProcess:(BOOL)owned forDeviceID:(AudioDeviceID)deviceID;

@end

NS_ASSUME_NONNULL_END

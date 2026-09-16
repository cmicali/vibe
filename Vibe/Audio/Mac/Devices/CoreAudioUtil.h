//
//  CoreAudioUtil.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

// Raw HAL property accessors. Device
// enumeration, AudioDevice model lookup and device-change notifications live
// in AudioDeviceManager.
@interface CoreAudioUtil : NSObject

// Convenience for device-switch paths which must act on the current answer.
// Returns kAudioObjectUnknown for either no default or a read failure; snapshot
// code must use the tri-state form below instead.
+ (AudioDeviceID)systemDefaultOutputDeviceID;

// Restore/release a recorded device change, retrying a transient failure once.
// A failed operation keeps the slot unless a published snapshot proves removal.
// Callers run on their owning queue; supplied operations are synchronous.
+ (BOOL)releaseDeviceObligation:(AudioDeviceID *)deviceID
                       attempt:(BOOL (^)(void))attempt
                      isAbsent:(BOOL (^)(AudioDeviceID deviceID))isAbsent;

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

// The device's nominal sample rate: a physical-format write is applied
// asynchronously by the HAL, so a caller that needs the new rate to be in
// effect reads this back.
+ (BOOL)readNominalSampleRate:(Float64 *)rate forDeviceID:(AudioDeviceID)deviceID;

// The device's first output stream: its id, its current physical format and
// the formats it offers. availableFormats is malloc'd and owned by the caller
// (free() it); it is NULL with count 0 when the stream lists none.
+ (BOOL)readOutputStream:(AudioStreamID *)stream
          physicalFormat:(AudioStreamBasicDescription *)format
        availableFormats:(AudioStreamRangedDescription * _Nullable * _Nonnull)availableFormats
                   count:(UInt32 *)count
             forDeviceID:(AudioDeviceID)deviceID;
// kAudioStreamPropertyPhysicalFormat, which carries rate and depth together.
+ (BOOL)readPhysicalFormat:(AudioStreamBasicDescription *)format forStream:(AudioStreamID)stream;
+ (BOOL)setPhysicalFormat:(AudioStreamBasicDescription)format forStream:(AudioStreamID)stream;

// Read the output AU's live destination-indexed channel map. Source channels
// must reach the prepared stream in order, with every unused output silent.
+ (BOOL)outputUnit:(AudioUnit)unit preservesChannels:(UInt32)channels
          inStream:(AudioStreamID)stream physicalChannelCount:(UInt32)physicalChannels;

// Optional output controls. Missing controls mean unity volume, centered
// balance (0.5), or unmuted; a failed read of a present control returns NO.
// Includes main controls and each source channel starting at the stream's
// first channel. Volume is the lowest scalar, not a compounded gain.
+ (BOOL)readOutputVolume:(Float32 *)volume balance:(Float32 *)balance mute:(BOOL *)muted
               channels:(UInt32)channels inStream:(AudioStreamID)stream
            forDeviceID:(AudioDeviceID)deviceID;
// One listener for all output elements, delivered on queue.
// The caller filters addresses for volume/balance/mute. The block is the handle:
// removal must use the same block object, queue and device.
+ (BOOL)addOutputLevelListener:(AudioObjectPropertyListenerBlock)listener
                        queue:(dispatch_queue_t)queue
                  forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)removeOutputLevelListener:(AudioObjectPropertyListenerBlock)listener
                           queue:(dispatch_queue_t)queue
                     forDeviceID:(AudioDeviceID)deviceID;

#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
// kAudioDevicePropertyHogMode. TRAP: setting hog mode ignores the value
// written and TOGGLES ownership — if this process owns it, a set releases it.
// So this reads first and writes only when the owner has to change, which
// makes it idempotent. YES means the device is in the requested state on
// return; "owned by this process" is the whole state, so a release while
// another process holds it is already true.
+ (BOOL)readHogOwner:(pid_t *)owner forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)setHogOwnedByThisProcess:(BOOL)owned forDeviceID:(AudioDeviceID)deviceID;
#endif

@end

NS_ASSUME_NONNULL_END

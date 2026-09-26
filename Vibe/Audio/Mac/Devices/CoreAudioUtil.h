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
// The documented persistent identifier for the device's MODEL, not the unit:
// two of the same interface share it. Unlike the device UID it carries no USB
// location, so it survives a port change. Compared as an opaque token, never
// parsed. Optional, like the UID: absent is a complete read.
+ (BOOL)readModelUID:(NSString * _Nullable * _Nonnull)modelUID
          forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)readName:(NSString * _Nullable * _Nonnull)name
      forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)readHasOutputChannels:(BOOL *)hasOutputChannels
                  forDeviceID:(AudioDeviceID)deviceID;

// kAudioDevicePropertyTransportType. An optional refinement: the sweep keeps a
// device whose transport is unreadable, as kAudioDeviceTransportTypeUnknown.
// Asks the device itself whether it still exists, rather than a snapshot that
// may not have caught up with an unplug. YES only when confirmed; a failed
// read answers NO (see VibeDeviceIsConfirmedDead).
+ (BOOL)deviceIsConfirmedDead:(AudioDeviceID)deviceID;

+ (BOOL)readTransportType:(UInt32 *)transportType forDeviceID:(AudioDeviceID)deviceID;

// YES only for an aggregate this process created privately — the one CoreAudio
// builds over the system default when the engine follows it, which is visible
// to no other process and cannot be chosen as an output. Answered from the
// composition dictionary's kAudioAggregateDeviceIsPrivateKey, so a public
// aggregate the user built stays a real device. Deliberately not a tri-state:
// every failure, including the property being absent on an ordinary device,
// answers NO and keeps the device, because a device missing from the list is
// worse than one wrongly kept.
+ (BOOL)isProcessPrivateAggregateDevice:(AudioDeviceID)deviceID;

// The device's nominal sample rate: a physical-format write is applied
// asynchronously by the HAL, so a caller that needs the new rate to be in
// effect reads this back.
+ (BOOL)readNominalSampleRate:(Float64 *)rate forDeviceID:(AudioDeviceID)deviceID;

// The device's first output stream: its id, its current physical format and,
// when asked for, the formats it offers. availableFormats is malloc'd and
// owned by the caller (free() it); it is NULL with count 0 when the stream
// lists none. Both NULL skips that enumeration, a HAL query of its own that
// a reader of the current format alone has no use for.
+ (BOOL)readOutputStream:(AudioStreamID *)stream
          physicalFormat:(AudioStreamBasicDescription *)format
        availableFormats:(AudioStreamRangedDescription * _Nullable * _Nullable)availableFormats
                   count:(UInt32 * _Nullable)count
             forDeviceID:(AudioDeviceID)deviceID;
// kAudioStreamPropertyPhysicalFormat, which carries rate and depth together.
+ (BOOL)readPhysicalFormat:(AudioStreamBasicDescription *)format forStream:(AudioStreamID)stream;
+ (BOOL)setPhysicalFormat:(AudioStreamBasicDescription)format forStream:(AudioStreamID)stream;

// An output AU's destination-indexed channel map (AudioOutputUnit.channelMap).
// Source channels must reach the prepared stream in order, with every unused
// output silent.
+ (BOOL)channelMap:(nullable NSArray<NSNumber *> *)map preservesChannels:(UInt32)channels
          inStream:(AudioStreamID)stream physicalChannelCount:(UInt32)physicalChannels;

// Optional output controls. Missing controls mean unity volume, centered
// balance (0.5), or unmuted; a failed read of a present control returns NO.
// Includes main controls and each source channel starting at the stream's
// first channel. Volume is the lowest scalar, not a compounded gain.
+ (BOOL)readOutputVolume:(Float32 *)volume balance:(Float32 *)balance mute:(BOOL *)muted
               channels:(UInt32)channels inStream:(AudioStreamID)stream
            forDeviceID:(AudioDeviceID)deviceID;
// One listener for all output elements and the device's nominal rate,
// delivered on queue. The caller filters addresses for volume/balance/mute and
// the rate. The block is the handle: removal must use the same block object,
// queue and device.
+ (BOOL)addOutputLevelListener:(AudioObjectPropertyListenerBlock)listener
                        queue:(dispatch_queue_t)queue
                  forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)removeOutputLevelListener:(AudioObjectPropertyListenerBlock)listener
                           queue:(dispatch_queue_t)queue
                     forDeviceID:(AudioDeviceID)deviceID;
// The device's nominal rate alone, delivered on queue; the block is the
// handle, as above.
+ (BOOL)addNominalRateListener:(AudioObjectPropertyListenerBlock)listener
                        queue:(dispatch_queue_t)queue
                  forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)removeNominalRateListener:(AudioObjectPropertyListenerBlock)listener
                           queue:(dispatch_queue_t)queue
                     forDeviceID:(AudioDeviceID)deviceID;

// Everything the HAL will say about one device, for Save Debug Info: identity,
// liveness and exclusive ownership, rates and buffer, the latency it declares,
// its clock, and its first output stream's formats and controls. Strings and
// numbers only, and a property the device does not answer is simply absent.
// Every read goes through coreaudiod, so call it off main.
+ (NSDictionary<NSString *, id> *)diagnosticDescriptionOfDeviceID:(AudioDeviceID)deviceID;

#if VIBE_VERBOSE_LOGGING
// Beta instrumentation (#47): one changed HAL property as a log phrase with
// its new value ("nominal rate = 44100 Hz", "exclusive owner = 1377 (Vibe)"),
// for the device event log. Reads through coreaudiod; call it off main.
+ (NSString *)eventDescriptionOfProperty:(AudioObjectPropertyAddress)address object:(AudioObjectID)object;
#endif

#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
// A writable hog property permits an attempt, not a promise of ownership.
+ (BOOL)supportsHogModeForDeviceID:(AudioDeviceID)deviceID;

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

//
//  AudioPlayer+DevicesInternal.h
//  Vibe
//
//  The macOS player's private device surface: the output-device ivars, and
//  the queue-side methods of (DevicesInternal) and (BitPerfectInternal) that
//  the rest of the player and the tests reach. AudioPlayerInternal.h imports
//  it under TARGET_OS_OSX, and nothing else does. AudioPlayer.m sees the
//  ivars through that import.
//

#import "AudioPlayer+BitPerfect.h"
#import "AudioPlayer+Devices.h"
#import "AudioDeviceManager.h"
#import "OutputFormatRules.h"
#import <AVFAudio/AVFAudio.h>
#import <CoreAudio/CoreAudio.h>

@class AudioFileHandle;

NS_ASSUME_NONNULL_BEGIN

// The longest the player queue waits on one bounded HAL read.
static const NSTimeInterval kDeviceReadWaitSeconds = 0.5;

@interface AudioPlayer () {
    // ---- The output device: the device _outputUnit is bound to.
    // AudioPlayer+Devices.m and AudioPlayer+BitPerfect.m own every field below.
    // The bound device's nominal rate and hog owner, watched in every mode:
    // another process moving the rate rebinds the unit at the new rate, and
    // one taking the device parks playback and refuses starts until it lets
    // go (_boundDeviceHeldElsewhere). Delivered on the queue.
    AudioObjectPropertyListenerBlock _boundDeviceListener;
    AudioDeviceID           _boundDeviceListenerDeviceID;
    BOOL                    _boundDeviceHeldElsewhere;
    // The launch preference awaiting a successful HAL snapshot and bind.
    // Queue-confined. Until binding succeeds the output honestly follows
    // System Output (-1).
    NSString                *_pendingSavedDeviceUID;
    NSString                *_pendingSavedDeviceModelUID;
    NSString                *_pendingSavedDeviceName;
    // The concrete device this player last committed to, so a device that
    // VANISHES can be told apart from System Output the user chose.
    NSString                *_boundDeviceUID;
    NSString                *_boundDeviceModelUID;
    NSString                *_boundDeviceName;
    // Set only across one selectOutputDeviceOnQueue: call, when a wanted device
    // was found by its model UID under a new device UID: whose remembered modes
    // that bind should read. Nil means the device's own.
    NSString                *_modesUIDForNextSelection;
    // _stateLock: destination -> source until main has persisted the carry.
    NSMutableDictionary<NSString *, NSString *> *_unpersistedOutputModeSources;
    // Covers the async manager lookup and its checked bind, so a failed bind
    // resetting to Stopped cannot start another attempt.
    BOOL                    _pendingSavedDeviceLookupInFlight;
    // Coalesces the single delayed retry after a system-default read fails.
    BOOL                    _systemOutputBindRetryScheduled;
    // Bit-perfect output: the settings' queue-side intent.
    BOOL                    _bitPerfectWanted;
    BOOL                    _allowBitPerfectOnAnyDevice;
    // The device configureOutputDeviceOnQueue: is rebinding to, for the
    // duration of that call, else kAudioObjectUnknown.
    AudioDeviceID           _rebindDeviceID;
    BOOL                    _exclusiveOutputWanted;
    // Possible ownership, or kAudioObjectUnknown; retained until release is
    // confirmed, never overwritten by another device.
    AudioDeviceID           _hoggedDeviceID;
    // The one device whose format this run changed and has not yet put back.
    AudioDeviceID           _changedFormatDeviceID;
    AudioStreamID           _changedFormatStreamID;
    AudioStreamBasicDescription _formatBeforeChange;
    // The device the last prepare set up: its first output stream, the format
    // asked of it, and the listeners the HAL holds on it.
    AudioDeviceID           _preparedDeviceID;
    AudioStreamID           _preparedStreamID;
    AudioStreamBasicDescription _preparedFormat;
    AudioObjectPropertyListenerBlock _outputLevelListener;
    // The prepared device's volume, balance and mute as the report last read
    // them, trusted only while _outputLevelListener is registered.
    AudioDeviceID           _outputControlsDeviceID;
    AudioStreamID           _outputControlsStreamID;
    UInt32                  _outputControlsChannels;
    Float32                 _outputControlsVolume;
    Float32                 _outputControlsBalance;
    BOOL                    _outputControlsMuted;
    // The published report, under _stateLock.
    VibeBitPerfectReport    _bitPerfectReport;
}
@end

// Only the entry points used outside AudioPlayer+Devices.m.
@interface AudioPlayer (DevicesInternal) <AudioDeviceManagerObserver>

// The output unit, made now if it could not be made at init. A unit brings its
// device's rate, so a source segment built at the fallback format follows
// it here — the current voice restarted at its intent — before anything is
// built or started at the old one. YES with a unit, or under the pump,
// which needs none; NO with none, which the next start reports. Runs before
// a settlement builds its segment and before a resume starts.
- (BOOL)ensureOutputUnitOnQueue;
- (BOOL)createOutputUnitOnQueue;
// Brings the unit and the pipeline to `rate`: the output stopped, the unit
// reconfigured, the FX chain re-hosted, the meter replaced. The voice bus is
// the caller's to reconcile (reconcileSourceSegmentOnQueue), which rebuilds
// one at the old rate and re-voices. A
// no-op at the current rate. NO without a unit; a format the HAL refuses
// fails the next start instead (AudioOutputUnit.h).
- (BOOL)applyOutputRateOnQueue:(double)rate;

// Resolves the retained launch preference without blocking _queue. It only
// applies a found device where VibeCanBindSavedOutputDevice allows — Stopped,
// a settled Pause, or Loading while the output is not running — and playback
// winning the lookup race leaves the preference
// pending for the next eligible transition or device/default refresh. Runs on
// _queue. A completed missing-device lookup disables an armed bit-perfect
// mode; an unpublished snapshot never settles that lookup.
- (void)resolvePendingSavedOutputDeviceOnQueue;

// The HAL bind boundary, replaced by a refusal in the device-free render
// tests: binds the hosted unit, which moves on its own only off a device that
// vanished. Stopped only.
- (BOOL)setOutputUnitDevice:(AudioDeviceID)deviceID;
// System Output's one coalesced delayed bind, for a default the snapshot does
// not name yet. A timer boundary: the render test that leaves the default
// unnamed replaces it, or a slow run meets the retry in its replay.
- (void)scheduleSystemOutputBindRetryOnQueue;
// Brings the pipeline to the bound device's nominal rate, so the unit never
// resamples; an unreadable rate keeps the current one. Reads whether another
// process holds the device in the same bounded read. After every bind.
- (void)followOutputDeviceRateOnQueue;

// AudioPlayer+BitPerfect.m calls these.
- (AudioDeviceID)activeOutputDeviceID;
- (BOOL)configureOutputDeviceOnQueue:(AudioDeviceID)deviceID;
- (void)readOutputModesForDeviceUID:(nullable NSString *)deviceUID
                  bitPerfectOutput:(BOOL *)bitPerfectOutput
                   exclusiveOutput:(BOOL *)exclusiveOutput;

@end

// Only the entry points used outside AudioPlayer+BitPerfect.m.
@interface AudioPlayer (BitPerfectInternal)

// Whether prepareOutputOnQueueForFile: would stop the output for a switch —
// the gapless successor's gate, since a continuation on one voice cannot
// switch the device. NO whenever the mode cannot apply; YES for a format the
// device will not report, since unknown compatibility cannot splice.
- (BOOL)outputNeedsSwitchOnQueueForFile:(AudioFileHandle *)file;

// Reads the bound device's capabilities, applies the rate and depth rules,
// and when the device's format or the graph's rate differs, stops the
// output — the callers guarantee nothing is audible — writes one physical
// format, waits (bounded) for the device to confirm it, and brings the graph
// to the device's rate. Remembers the device's format before the first
// change so it can be put back, and records the prepared device, stream and
// format the report reads live against.
- (void)prepareOutputOnQueueForFile:(AudioFileHandle *)file;

// Hogs the bit-perfect device (the requested one, or a switch's destination)
// when the setting, an eligible device and writable HAL hog mode all hold.
// Idempotent through the HAL read; a rebuild on the device already hogged
// keeps the hog. Taking the system default moves the default elsewhere; the
// hosted unit stays.
- (void)acquireExclusiveOutputOnQueue;
- (void)releaseExclusiveOutputOnQueue;

// Computes the report from its owners and publishes the copy the shell
// reads, announcing it to the delegate when it differs. Its edges are
// refreshOutputAudioActiveOnQueue (every state publication and voice end),
// the end of a device switch, the two hog edges, the mode toggle, a
// volume/balance/mute change and a system-default change.
- (void)publishBitPerfectReportOnQueue;
// The player's volume alone moved: refolds the published report with it, no
// device read, since a slider drag lands here every tick.
- (void)refoldBitPerfectReportForPlayerVolumeOnQueue:(float)volume;

// AudioPlayer+Devices.m calls these.
- (void)abandonBitPerfectForVanishedDeviceOnQueue;
- (void)leaveOutputDeviceOnQueue;

@end

NS_ASSUME_NONNULL_END

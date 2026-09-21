//
//  AudioPlayer+Devices.h
//  Vibe
//
//  The internal surface of the output-device code: device switching,
//  config-change recovery and no-device parking. The public device API is
//  AudioPlayer.h's (Devices) category; AudioPlayer+Devices.m implements both.
//

#import "AudioPlayer.h"
#import "AudioDeviceManager.h"
#import "OutputFormatRules.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

// Only the entry points used outside AudioPlayer+Devices.m. The report is
// platform-specific, so it belongs here rather than in AudioPlayer.h.
@interface AudioPlayer (DevicesInternal) <AudioDeviceManagerObserver>

// The newest published report — a locked snapshot, no queue hop, like
// outputAudioActive. Recomputed from its owners at every settlement, hog
// edge, mode toggle, playback-state publication, volume/balance/mute change and default
// change, and announced through audioPlayerDidChangeBitPerfectReport: when
// it differs.
@property (readonly) VibeBitPerfectReport bitPerfectReport;

// Non-nil only while announcing a fallback to System Output that the user did
// NOT ask for — the bound device vanished or failed. The shell reads it to
// keep the saved preference instead of erasing it, so the device is re-adopted
// when it comes back, including across a relaunch. An explicit System Output
// selection leaves it nil and clears the preference as before.
@property (readonly, nullable) NSString *involuntaryFallbackDeviceUID;
@property (readonly, nullable) NSString *involuntaryFallbackDeviceName;

// Resolves the retained launch preference without blocking _queue. It only
// applies a found device where VibeCanBindSavedOutputDevice allows — Stopped,
// or Loading while the engine is not running; the rule and its trap are on
// that function — and playback winning the lookup race leaves the preference
// pending for the next eligible transition or device/default refresh. Runs on
// _queue. A completed missing-device lookup disables an armed bit-perfect
// mode; an unpublished snapshot never settles that lookup.
- (void)resolvePendingSavedOutputDeviceOnQueue;

// The AVAudioEngineConfigurationChangeNotification handler. The observer that
// AudioPlayer's init installs dispatches it onto _queue.
- (void)handleEngineConfigurationChange;

// The HAL bind boundary, replaced by a refusal in the device-free render tests.
- (BOOL)setOutputUnitDevice:(AudioDeviceID)deviceID;

// Whether prepareOutputOnQueueForFile: would stop the engine for a switch —
// the settlement's park predicate, which decides BEFORE the request is
// consumed, and the gapless splice's gate, since a splice cannot switch. NO
// whenever the mode cannot apply. Unknown format waits for outgoing silence
// and cannot splice; paused recovery must not rebuild from its own events.
- (BOOL)outputNeedsSwitchOnQueueForFile:(AVAudioFile *)file unknownNeedsSwitch:(BOOL)unknownNeedsSwitch;

// Reads the bound device's capabilities, applies the rate and depth rules,
// and when the device's format or the master bus's rate differs, stops the
// engine — the callers guarantee nothing is audible — writes one physical
// format, waits (bounded) for the device and output unit to agree, and rewires the
// master bus at the device's rate. Remembers the device's format before the
// first change so it can be put back, and records the prepared device,
// stream and format the report reads live against.
- (void)prepareOutputOnQueueForFile:(AVAudioFile *)file;

#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
// Hog for the bound device, when the setting, an eligible device and writable
// HAL hog mode all hold. Idempotent through the HAL read; a rebuild on the
// device already hogged keeps the hog. Taking the device that is currently
// the system default moves the default and drags the output unit with it, so
// the acquisition settles the binding before the caller starts the engine.
- (void)acquireExclusiveOutputOnQueue;
- (void)releaseExclusiveOutputOnQueue;
#endif

// Computes the report from its owners and publishes the copy the shell
// reads, announcing it to the delegate when it differs. Its edges are
// refreshOutputAudioActiveOnQueue (every state publication and fade
// completion), the end of a device switch, the two hog edges, the mode
// toggle, a volume/balance/mute change and a system-default change.
- (void)publishBitPerfectReportOnQueue;

@end

NS_ASSUME_NONNULL_END

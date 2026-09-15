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

// The shell-facing half of bit-perfect output: what the header glyph, the
// Settings caption and dump_state read. It sits here rather than in
// AudioPlayer.h because the report is OutputFormatRules.h's type, which only
// this platform's tree has.
@interface AudioPlayer (BitPerfect)

// The newest published report — a locked snapshot, no queue hop, like
// outputAudioActive. Recomputed at every settlement, hog edge, mode toggle and
// playback-state publication.
@property (readonly) VibeBitPerfectReport bitPerfectReport;

@end

@interface AudioPlayer (DevicesInternal) <AudioDeviceManagerObserver>

// The AudioDeviceID the output unit is currently bound to.
- (AudioDeviceID)activeOutputDeviceID;

// A raw bind of the engine's output unit to deviceID, with no graph rebuild
// or restore.
- (BOOL)setOutputUnitDevice:(AudioDeviceID)deviceID;

// Resolves the retained launch preference without blocking _queue. It only
// applies a found device where VibeCanBindSavedOutputDevice allows — Stopped,
// or Loading while the engine is not running; the rule and its trap are on
// that function — and playback winning the lookup race leaves the preference
// pending for the next eligible transition or device/default refresh. Runs on
// _queue.
- (void)resolvePendingSavedOutputDeviceOnQueue;

// Rebinds the engine to a new output device, restoring the current track, the
// position and the play or pause state. Runs on _queue.
- (BOOL)configureOutputDeviceOnQueue:(AudioDeviceID)deviceID;

// Parks a playing track as Paused when the last output device has vanished.
// Runs on _queue.
- (void)parkPlaybackForMissingOutputDeviceOnQueue;

// The AVAudioEngineConfigurationChangeNotification handler. The observer that
// AudioPlayer's init installs dispatches it onto _queue.
- (void)handleEngineConfigurationChange;

@end

// Bit-perfect output's queue-side mechanism, split from (DevicesInternal) so
// each category's header block matches its implementation block. All on
// _queue.
@interface AudioPlayer (BitPerfectMechanism)

// Whether prepareOutputOnQueueForFile: would stop the engine for a switch —
// the settlement's park predicate, which decides BEFORE the request is
// consumed. NO whenever the mode cannot apply.
- (BOOL)outputNeedsSwitchOnQueueForFile:(AVAudioFile *)file;

// Whether the mixer feeds the output node at a rate other than `rate`, so
// the output unit resamples. The device switch and the settlement both ask.
- (BOOL)masterBusRateDiffersFrom:(double)rate;

// Reads the bound device's capabilities, applies the rate and depth rules,
// and when the device's format or the master bus's rate differs, stops the
// engine — the callers guarantee nothing is audible — writes one physical
// format, waits (bounded) for the nominal rate to read back, and rewires the
// master bus at the device's rate. Remembers the device's format before the
// first change so it can be put back. It writes the report's facts; the
// state publication every caller makes next publishes them.
- (void)prepareOutputOnQueueForFile:(AVAudioFile *)file;

// Hog for the bound device, when the mode, an eligible device, no FX graph
// and a non-virtual transport all hold. Idempotent through the HAL read.
- (void)acquireExclusiveOutputOnQueue;
- (void)releaseExclusiveOutputOnQueue;

// Writes the remembered format back to the device it was read from when one
// is owed, and clears the slot either way — a vanished device fails the write
// and is simply forgotten. No read-back wait: the HAL owns the change once
// the call returns.
- (void)restoreOutputFormatOnQueue;

// Folds the queue-side facts against the live state and publishes the copy
// the shell reads. Its edges are refreshOutputAudioActiveOnQueue (every
// state publication and fade completion), the committed device id, the two
// hog edges and the mode toggle.
- (void)publishBitPerfectReportOnQueue;

// The parked settlement's re-entry, called by completeRetiredFadePair: when
// the last counted fade is silent.
- (void)runParkedSettlementOnQueue;

// The chosen device vanished: drops the mode, the hog and the owed format
// without touching a device that is gone. The two fallback sites call it
// before falling back to System Output.
- (void)abandonBitPerfectForVanishedDeviceOnQueue;

// Whether the chain is built without a varispeed — the mode's pruning follows
// the switch, so a run with it on never mints one. The retire path and the
// device restore both ask.
- (BOOL)chainOmitsVarispeed;

@end

NS_ASSUME_NONNULL_END

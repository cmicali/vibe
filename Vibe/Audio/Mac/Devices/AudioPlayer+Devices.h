//
//  AudioPlayer+Devices.h
//  Vibe
//
//  The output-device half of the player, macOS only: which device the hosted
//  output unit is bound to and at what rate, the bit-perfect and exclusive
//  modes, no-device parking and the report. It owns the AudioOutputUnit carrier.
//  (Devices) is the public API a shell imports beside AudioPlayer.h; (DevicesInternal) is what the rest of the player and the
//  tests reach. AudioPlayer+Devices.m implements both. It lives under Mac/ so
//  only the macOS target compiles it: a shared caller would compile on iOS
//  and fail at link.
//

#import "AudioPlayer.h"
#import "AudioDeviceManager.h"
#import "OutputFormatRules.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

@class AudioFileHandle;

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Devices)

// outputDeviceID is a CoreAudio AudioDeviceID held as an NSInteger, or -1 to
// follow the system default output. It is not a menu or array index. Device
// IDs do not survive a reboot, so persistence goes by UID and name; see
// initWithDeviceUID:. The delegate supplies the destination UID's modes
// before its one rebuild. Completion runs on main after settlement (including
// failure), so the shell can keep mode edits disabled until persistence settles.
- (void)setOutputDevice:(NSInteger)outputDeviceID completion:(dispatch_block_t)completion;

// Bit-perfect output. While on, each track's settlement sets the chosen
// device to the file's rate and word length, and the source segment is the
// bus at the file's own format straight into the mixer, without varispeed;
// the only gain ever applied is the declick at each transport edge, and none
// with AudioPlayer.declick off, when every edge is a cut. The shell owns
// the rest of the pruning (minimum crossfade, hidden pitch fader) and only
// turns this on for an eligible device — explicitly chosen, on a transport
// that carries bits unchanged (OutputFormatRules.h). Either direction
// restores the current track in place, as a device switch onto the same
// device; off also puts the device's format back and releases the hog. Main
// thread, like every other transport-facing setter; the work lands on the
// player queue. The delegate rereads the current UID's modes on the player
// queue; explicit flags supply submission-time FX cleanup and the fallback
// without a provider. Bit-perfect outranks the saved FX choice. Exclusive
// access applies only in bit-perfect mode; the build flag can remove it.
// allowAnyDevice bypasses only transport eligibility for Advanced testing.
- (void)setBitPerfectOutput:(BOOL)bitPerfectOutput exclusiveOutput:(BOOL)exclusiveOutput
                  enableFX:(BOOL)enableFX allowAnyDevice:(BOOL)allowAnyDevice;

// Permanently stops transport, restores any changed device format and releases the hog,
// synchronously on the player queue, so it waits on the device. The app
// delegate's applicationShouldTerminate: is the one caller, off main and after
// the windows are gone and its playback delegate is detached on main: this is
// the edge that keeps the restore promise.
- (void)prepareForTermination;

@end

// Only the entry points used outside AudioPlayer+Devices.m.
@interface AudioPlayer (DevicesInternal) <AudioDeviceManagerObserver>

// The carrier, made now if it could not be made at init. A unit brings its
// device's rate, so a source segment built at the fallback format follows
// it here — the current voice restarted at its intent — before anything is
// built or started at the old one. YES with a unit, or under the pump,
// which needs none; NO with none, which the next start reports. Runs before
// a settlement builds its segment and before a resume starts.
- (BOOL)ensureOutputUnitOnQueue;
- (BOOL)createOutputUnitOnQueue;
// Brings the unit and the pipeline to `rate`: the output stopped, the unit
// reconfigured, the FX chain re-hosted, the meter replaced. The bus is the
// caller's to reconcile through ensureSourceSegmentOnQueueRebuilt:, which
// rebuilds one at the old rate and reports it, so the caller re-voices. A
// no-op at the current rate. NO without a unit, or when the unit refuses.
- (BOOL)applyOutputRateOnQueue:(double)rate;


// The newest published report — a locked snapshot, no queue hop, like
// outputAudioActive. Recomputed from its owners at every settlement, hog
// edge, mode toggle, playback-state publication, volume/balance/mute change and default
// change, and announced through audioPlayerDidChangeBitPerfectReport: when
// it differs.
@property (readonly) VibeBitPerfectReport bitPerfectReport;

// The same report as a dictionary with its status named: every input to the
// fold, so a reader can say why a lock is open. Save Debug Info and the debug
// channel's dump_state both read it.
- (NSDictionary<NSString *, id> *)bitPerfectReportDictionary;

// Queue snapshot of pending identity, device obligations and actual graph rates.
// Save Debug Info reads off main; debug commands may deliberately wait.
- (NSDictionary<NSString *, id> *)outputDeviceDiagnosticSnapshot;

// Resolves the retained launch preference without blocking _queue. It only
// applies a found device where VibeCanBindSavedOutputDevice allows — Stopped,
// a settled Pause, or Loading while the output is not running; the rule and its trap are on
// that function — and playback winning the lookup race leaves the preference
// pending for the next eligible transition or device/default refresh. Runs on
// _queue. A completed missing-device lookup disables an armed bit-perfect
// mode; an unpublished snapshot never settles that lookup.
- (void)resolvePendingSavedOutputDeviceOnQueue;

// The HAL bind boundary, replaced by a refusal in the device-free render
// tests: binds the hosted unit, which never moves on its own. Stopped only.
- (BOOL)setOutputUnitDevice:(AudioDeviceID)deviceID;
// Brings the pipeline to the bound device's nominal rate, so the unit never
// resamples; an unreadable rate keeps the current one. After every bind.
- (void)followOutputDeviceRateOnQueue;

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

// VibeBitPerfectDecodesAsInteger16 against the device prepared for file: the
// voice's decode format. Read after preparing, which every caller does.
- (BOOL)decodesAsInteger16OnQueueForFile:(AudioFileHandle *)file;

#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
// Hog for the bound device, when the setting, an eligible device and writable
// HAL hog mode all hold. Idempotent through the HAL read; a rebuild on the
// device already hogged keeps the hog. Taking the device that is currently
// the system default moves the default elsewhere; the hosted unit stays.
- (void)acquireExclusiveOutputOnQueue;
- (void)releaseExclusiveOutputOnQueue;
#endif

// Computes the report from its owners and publishes the copy the shell
// reads, announcing it to the delegate when it differs. Its edges are
// refreshOutputAudioActiveOnQueue (every state publication and voice end),
// the end of a device switch, the two hog edges, the mode toggle, a
// volume/balance/mute change and a system-default change.
- (void)publishBitPerfectReportOnQueue;

@end

NS_ASSUME_NONNULL_END

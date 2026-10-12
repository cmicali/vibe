//
//  AudioPlayer+BitPerfect.h
//  Vibe
//
//  Bit-perfect and exclusive output, macOS only: the setter a shell calls and
//  the report it reads. (BitPerfect) is the public API a shell imports beside
//  AudioPlayer.h. The queue-side mechanism, (BitPerfectInternal), is declared
//  in AudioPlayer+DevicesInternal.h. It lives under Mac/ so only the macOS
//  target compiles it.
//

#import "AudioPlayer.h"
#import "OutputFormatRules.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (BitPerfect)

// Bit-perfect output. While on, each track's settlement sets the chosen
// device to the file's rate and word length, and the source segment is the
// bus at the file's own format, without varispeed;
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
// access applies only in bit-perfect mode.
// allowAnyDevice bypasses only transport eligibility for Advanced testing.
- (void)setBitPerfectOutput:(BOOL)bitPerfectOutput exclusiveOutput:(BOOL)exclusiveOutput
                  enableFX:(BOOL)enableFX allowAnyDevice:(BOOL)allowAnyDevice;

// The newest published report — a locked snapshot, no queue hop, like
// outputAudioActive. Recomputed from its owners at every settlement, hog
// edge, mode toggle, playback-state publication, volume/balance/mute change
// and default change, and announced through
// audioPlayerDidChangeBitPerfectReport: when it differs.
@property (readonly) VibeBitPerfectReport bitPerfectReport;

// The same report as a dictionary with its status named: every input to the
// fold, so a reader can say why a lock is open. Save Debug Info and the debug
// channel's dump_state both read it.
- (NSDictionary<NSString *, id> *)bitPerfectReportDictionary;

@end

NS_ASSUME_NONNULL_END

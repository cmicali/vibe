//
//  AudioPlayer+Devices.h
//  Vibe
//
//  The output-device half of the player, macOS only: which device the hosted
//  output unit is bound to, termination and the device report. (Devices) is
//  the public API a shell imports beside AudioPlayer.h. Bit-perfect output has
//  its own header, AudioPlayer+BitPerfect.h. The queue side is in
//  AudioPlayer+DevicesInternal.h. It lives under Mac/ so only the macOS target
//  compiles it: a shared caller would compile on iOS and fail at link.
//

#import "AudioPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Devices)

// outputDeviceID is a CoreAudio AudioDeviceID held as an NSInteger, or -1 to
// follow the system default output. It is not a menu or array index. Device
// IDs do not survive a reboot, so persistence goes by UID and name; see
// initWithDeviceUID:. The delegate supplies the destination UID's modes
// before its one rebuild. Completion runs on main after settlement (including
// failure), so the shell can keep mode edits disabled until persistence settles.
- (void)setOutputDevice:(NSInteger)outputDeviceID completion:(dispatch_block_t)completion;

// Permanently stops transport, restores any changed device format and
// releases the hog, synchronously on the player queue, so it waits on the
// device. The app
// delegate's applicationShouldTerminate: is the one caller, off main and after
// the windows are gone and its playback delegate is detached on main: this is
// the edge that keeps the restore promise.
- (void)prepareForTermination;

// Queue snapshot of pending identity, device obligations and actual graph rates.
// Save Debug Info reads off main; debug commands may deliberately wait.
- (NSDictionary<NSString *, id> *)outputDeviceDiagnosticSnapshot;

@end

NS_ASSUME_NONNULL_END

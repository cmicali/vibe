//
//  AudioFileMaterializationCoordinator+Debug.h
//  Vibe
//
//  Debug-only declaration for the path-wide admission counters.
//

#if DEBUG

#import "AudioFileMaterializationCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioFileMaterializationCoordinator (Debug)
- (NSDictionary<NSString *, NSNumber *> *)debugState;

// Wedge injection for stage 2. Opens of basename block inside the
// uncancellable AVAudioFile call until released — the one provider failure the
// fake cloud cannot stage, because under it the bytes are genuinely local and
// a real open never blocks. nil basename stops matching new opens without
// releasing the ones already held.
//
// Everything else the harness needs to reach this class is a transfer-side
// knob on VibeFakeCloud; this is the open side, and it lives here because the
// opener it wraps belongs to the coordinator.
+ (void)debugHangOpensForBasename:(nullable NSString *)basename;
+ (void)debugReleaseHungOpens;
+ (NSUInteger)debugHungOpenCount;
@end

NS_ASSUME_NONNULL_END

#endif

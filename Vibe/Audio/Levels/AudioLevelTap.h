//
//  AudioLevelTap.h
//  Vibe
//
//  Demand-driven FFT analysis for the shared five-bar equalizer indicator.
//  AudioPlayer owns one publisher for its lifetime and replaces only the tap
//  session when an engine graph is rebuilt.
//

#import <AVFoundation/AVFoundation.h>

#import "AudioLevelMath.h"
#import "AudioLevelPublisher.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioLevelTap : NSObject

// Installs immediately on the owner's engine queue. The node's output format
// supplies the initial analyzer configuration and a legal buffer request; the
// delivered buffer format remains authoritative. nil is passed to
// installTapOnBus: because this is a connected output bus. Returns nil for a
// temporarily unusable format or any allocation/install failure. A later
// engine-start edge may retry. The normalization mode is fixed for the tap's
// lifetime; replace the tap to switch modes and reset its analysis history.
- (nullable instancetype)initWithNode:(AVAudioNode *)node
                             publisher:(AudioLevelPublisher *)publisher
                     normalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode
        NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Removes a tap from a live graph. Call on the same engine queue as init.
- (void)remove;

// Invalidates publication without messaging a defunct graph. The installed
// block strongly owns its plain state session, so a late callback is harmless
// and cannot touch freed memory.
- (void)abandon;

@end

NS_ASSUME_NONNULL_END

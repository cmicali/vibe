//
//  AudioLevelPublisherInternal.h
//  Vibe
//
//  The meter-session writer surface. Display clients use AudioLevelPublisher.h.
//

#import "AudioLevelPublisher.h"
#import <CoreAudioTypes/CoreAudioBaseTypes.h>
#import <stdatomic.h>

typedef struct VibeLevelPublisherState VibeLevelPublisherState;

// Visible here for the debug seam (AudioLevelPublisher+Debug.m), which reads
// the counters. Writers go through the functions below.
struct VibeLevelPublisherState {
    _Atomic uint64_t activeSession;
    _Atomic uint64_t nextSession;
    _Atomic uint64_t nextSequence;
    // Odd means a writer is changing the five level words; equal even values
    // before and after a read prove they came from one coherent publication.
    _Atomic uint64_t writeVersion;
    _Atomic bool writeClaimed;
    _Atomic uint64_t publishedSession;
    _Atomic uint64_t publishedSequence;
    _Atomic uint32_t levelBits[kLevelBandCount];
    // Debug builds only. Release never writes them.
    _Atomic uint64_t callbackCount;
    _Atomic uint64_t analyzedWindowCount;
    _Atomic uint64_t publicationCount;
    _Atomic uint64_t lastCallbackFrameLength;
    _Atomic uint64_t lastSampleRateBits;
};

NS_ASSUME_NONNULL_BEGIN

@interface AudioLevelPublisher (MeterSession)
- (VibeLevelPublisherState *)publisherState;
- (uint64_t)beginSession;
- (void)endSession:(uint64_t)session;
@end

// A single nonblocking write claim protects the rare overlap between a
// retired meter's last render and its replacement. Contention drops one
// target; it never spins or waits on the audio thread.
BOOL VibeLevelPublisherPublish(VibeLevelPublisherState *state,
                               uint64_t session,
                               const float levels[_Nonnull kLevelBandCount]) CA_REALTIME_API;

// Empty in Release: diagnostics stay out of the render without #if DEBUG in a
// header.
void VibeLevelPublisherRecordCallback(VibeLevelPublisherState *state,
                                      uint64_t frameLength,
                                      double sampleRate) CA_REALTIME_API;
void VibeLevelPublisherRecordAnalyzedWindows(VibeLevelPublisherState *state,
                                             uint64_t count) CA_REALTIME_API;

NS_ASSUME_NONNULL_END

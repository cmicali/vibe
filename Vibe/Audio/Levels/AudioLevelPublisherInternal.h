//
//  AudioLevelPublisherInternal.h
//  Vibe
//
//  Tap-session writer surface. Display clients use AudioLevelPublisher.h.
//

#import "AudioLevelPublisher.h"

typedef struct VibeLevelPublisherState VibeLevelPublisherState;

NS_ASSUME_NONNULL_BEGIN

@interface AudioLevelPublisher (TapSession)
- (VibeLevelPublisherState *)publisherState;
- (uint64_t)beginSession;
- (void)endSession:(uint64_t)session;
@end

// A single nonblocking write claim protects the rare overlap between an old
// abandoned engine callback and its replacement. Contention drops one target;
// it never spins or waits on the audio thread.
BOOL VibeLevelPublisherPublish(VibeLevelPublisherState *state,
                               uint64_t session,
                               const float levels[_Nonnull kLevelBandCount]);

// Called only from DEBUG tap code. Their Release bodies are empty, keeping
// diagnostics out of the render path without putting #if DEBUG in a header.
void VibeLevelPublisherRecordCallback(VibeLevelPublisherState *state,
                                      uint64_t frameLength,
                                      double sampleRate);
void VibeLevelPublisherRecordAnalyzedWindows(VibeLevelPublisherState *state,
                                             uint64_t count);

NS_ASSUME_NONNULL_END

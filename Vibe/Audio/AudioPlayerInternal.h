//
//  AudioPlayerInternal.h
//  Vibe
//
//  The private surface shared between AudioPlayer.m and AudioPlayer+Devices.m:
//  the player state enum, the error constructor, and the class extension
//  holding the ivars and queue-side helpers the output-device category needs.
//  Do not use it outside the AudioPlayer implementation files; everything else
//  goes through AudioPlayer.h.
//

#import "AudioPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibePlayerState) {
    VibePlayerStateStopped = 0,
    VibePlayerStatePlaying,
    VibePlayerStatePaused,
    // A play was requested and the file open is in flight, which can take up
    // to kFileOpenTimeoutSeconds for a cloud placeholder. There is no node or
    // file yet, but playback is imminent, so isPlaying reports YES and the UI
    // holds the pause icon, while position and duration read 0 rather than the
    // previous track's values.
    VibePlayerStateLoading,
};

// Defined in AudioPlayer.m.
NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying);
NSError *VibeAudioErrorForTrack(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying, NSURL * _Nullable trackURL);

// Seconds → start frame for scheduling, clamped to [0, fileLength - 1]: a
// past-the-end start lands on the last frame rather than scheduling an empty
// segment.
static inline AVAudioFramePosition VibeClampedStartFrame(NSTimeInterval seconds, double sampleRate, AVAudioFramePosition fileLength) {
    AVAudioFramePosition frame = (AVAudioFramePosition)(seconds * sampleRate);
    return MAX(0, MIN(frame, fileLength - 1));
}

@interface AudioPlayer () {
    // Only the ivars AudioPlayer+Devices.m also touches live here in the class
    // extension. Everything the device code never reaches stays declared, with
    // its commentary, in AudioPlayer.m's @implementation block.
    dispatch_queue_t        _queue;
    AVAudioEngine           *_engine;
    AVAudioPlayerNode       *_node;
    AVAudioFile             *_file;
    AVAudioFramePosition    _segmentStartFrame;
    uint64_t                _generation;
    // Bumped by every path that preempts an async volume ramp: pause, resume,
    // seek, skip and device switch. Each ramp step aborts once its captured
    // value goes stale, so a resume fade-in cannot drive the volume back up
    // after a pause.
    uint64_t                _rampGeneration;
    VibePlayerState         _state;
    os_unfair_lock          _stateLock;
}

// Readwrite here, readonly in AudioPlayer.h. Only the player itself writes
// them: currentTrack on _queue, and the device id from the init and device
// paths in both implementation files.
@property (nullable, strong, readwrite) AudioTrack *currentTrack;
@property (atomic, readwrite) NSInteger currentlyRequestedAudioDeviceId;

// Queue-side helpers implemented in AudioPlayer.m, whose definitions there
// carry the full contract comments. They are declared here so that
// AudioPlayer+Devices.m can call them. All of them run on _queue.
- (uint64_t)preemptRampsOnQueue;
- (BOOL)connectNode:(AVAudioPlayerNode *)node throughVarispeedWithFormat:(AVAudioFormat *)format;
- (void)detachNodeAfterFailedConnect:(AVAudioNode *)node;
// The two failure ballets shared by the play path and the device restore,
// kept in one home so intentional differences between those paths stay
// visible as differences at the call sites. Both run on _queue.
// attachConnectedNodeForFormat: mints a node and connects it through a fresh
// varispeed; on connect failure it detaches, resets to Stopped, reports
// description (against url when the failure names a track), and returns nil.
// abandonNodeAfterFailedStart: retires the scheduled segment's stop-fired
// completion, silences and detaches the node, resets to Stopped and reports.
- (nullable AVAudioPlayerNode *)attachConnectedNodeForFormat:(AVAudioFormat *)format
                                          failureDescription:(NSString *)description
                                                         url:(nullable NSURL *)url;
- (void)abandonNodeAfterFailedStart:(AVAudioPlayerNode *)node
                 failureDescription:(NSString *)description
                              error:(nullable NSError *)error
                                url:(nullable NSURL *)url;
- (void)scheduleFile:(AVAudioFile *)file onNode:(AVAudioPlayerNode *)node fromFrame:(AVAudioFramePosition)startFrame;
- (BOOL)startEngineAndPlayNode:(AVAudioPlayerNode *)node error:(NSError * _Nullable * _Nullable)outError;
- (void)resetToStoppedStateOnQueue;
- (void)publishPlaybackState:(VibePlayerState)state
                        node:(nullable AVAudioPlayerNode *)node
                        file:(nullable AVAudioFile *)file
                segmentStart:(AVAudioFramePosition)segmentStart
                    position:(NSTimeInterval)position;
- (void)sendDelegateError:(NSError *)error;

@end

NS_ASSUME_NONNULL_END

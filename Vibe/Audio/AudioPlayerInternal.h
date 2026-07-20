//
//  AudioPlayerInternal.h
//  Vibe
//
//  Private shared surface between AudioPlayer.m and AudioPlayer+Devices.m:
//  the player state enum, the error constructor, and the class extension with
//  the ivars and queue-side helpers the output-device category needs. Not for
//  use outside the AudioPlayer implementation files — everything else goes
//  through AudioPlayer.h.
//

#import "AudioPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

typedef NS_ENUM(NSInteger, VibePlayerState) {
    VibePlayerStateStopped = 0,
    VibePlayerStatePlaying,
    VibePlayerStatePaused,
    // A play was requested and the file open is in flight (can take up to
    // kFileOpenTimeoutSeconds for a cloud placeholder). No node/file yet, but
    // playback is imminent — isPlaying reports YES so the UI holds the pause
    // icon, while position/duration read 0 instead of the previous track's.
    VibePlayerStateLoading,
};

// Defined in AudioPlayer.m.
NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError *underlying);

@interface AudioPlayer () {
    // Only the ivars AudioPlayer+Devices.m also touches live here in the
    // class extension; everything the device code never reaches stays
    // declared (with its commentary) in AudioPlayer.m's @implementation
    // block.
    dispatch_queue_t        _queue;
    AVAudioEngine           *_engine;
    AVAudioPlayerNode       *_node;
    AVAudioFile             *_file;
    AVAudioFramePosition    _segmentStartFrame;
    uint64_t                _generation;
    // Bumped by every path that preempts an async volume ramp (pause, resume,
    // seek, skip, device switch); each ramp step aborts once its captured value
    // goes stale, so a resume fade-in can't drive volume back up after a pause.
    uint64_t                _rampGeneration;
    VibePlayerState         _state;
    os_unfair_lock          _stateLock;
}

// Queue-side helpers implemented in AudioPlayer.m (see the definitions there
// for the full contract comments); declared here so AudioPlayer+Devices.m can
// call them. All of these run on _queue.
- (uint64_t)preemptRampsOnQueue;
- (BOOL)connectNode:(AVAudioPlayerNode *)node throughVarispeedWithFormat:(AVAudioFormat *)format;
- (void)detachNodeAfterFailedConnect:(AVAudioNode *)node;
- (void)scheduleFile:(AVAudioFile *)file onNode:(AVAudioPlayerNode *)node fromFrame:(AVAudioFramePosition)startFrame;
- (BOOL)startEngineAndPlayNode:(AVAudioPlayerNode *)node error:(NSError **)outError;
- (void)resetToStoppedStateOnQueue;
- (void)publishPlaybackState:(VibePlayerState)state
                        node:(AVAudioPlayerNode *)node
                        file:(AVAudioFile *)file
                segmentStart:(AVAudioFramePosition)segmentStart
                    position:(NSTimeInterval)position;
- (void)sendDelegateError:(NSError *)error;

@end

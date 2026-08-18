//
//  AudioPlayer+Graph.h
//  Vibe
//
//  The player node and its varispeed: minting the pair, connecting it into the
//  engine, scheduling a file segment on it, and the two ways of abandoning it
//  when something fails.
//
//  Every track gets a *fresh* node and varispeed rather than reusing one, which
//  is what lets a track change crossfade on two independent chains with no
//  rerouting of the live node — and is why "attach, connect, schedule" is a
//  vocabulary of its own rather than setup code that runs once.
//
//  Everything here runs on the player queue.
//

#import "AudioPlayer.h"
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Graph)

- (BOOL)connectNode:(AVAudioPlayerNode *)node throughVarispeedWithFormat:(AVAudioFormat *)format;
- (void)detachNodeAfterFailedConnect:(AVAudioNode *)node;

// The two cleanup paths are shared by a submitted play and device restore,
// but error ownership is not. They reset to Stopped and never notify the
// delegate; each caller must report with the identity appropriate to its path.
- (nullable AVAudioPlayerNode *)attachConnectedNodeForFormat:(AVAudioFormat *)format;
- (void)abandonNodeAfterFailedStart:(AVAudioPlayerNode *)node;
- (void)scheduleFile:(AVAudioFile *)file onNode:(AVAudioPlayerNode *)node fromFrame:(AVAudioFramePosition)startFrame;

@end

NS_ASSUME_NONNULL_END

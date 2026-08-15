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

// The two failure paths, shared by the play path and the device restore so
// their intentional differences stay visible at the call sites.
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

@end

NS_ASSUME_NONNULL_END

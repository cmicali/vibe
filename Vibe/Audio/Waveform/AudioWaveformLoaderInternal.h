//
//  AudioWaveformLoaderInternal.h
//  Vibe
//
//  The decode pass's phases, declared so the tests can reach them one at a
//  time. The completeness rule reads the pass struct and needs no audio at
//  all, which is the point: a file that decodes a little short looks
//  identical on screen, so nothing but an assertion catches it.
//
//  Do not use this outside AudioWaveformLoader.mm and its tests.
//

#import "AudioWaveformLoader.h"
#import "AudioFileHandle.h"
#import "AudioWaveform.h"
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

// What the decode pass is told and what it reports back: a fact about the
// file, settled before the loop starts, or a fact about how far the loop got,
// which every later phase reads.
struct VibeWaveformDecodePass {
    // In: the window's place and length in the file, and its channels.
    AVAudioFramePosition windowStart;
    AVAudioFramePosition totalFrames;
    NSUInteger numChannels;
    // Out: how far it got, whether it stopped because a read failed, and
    // whether it met the end of the file.
    AVAudioFramePosition framesRead;
    BOOL readError;
    BOOL reachedEnd;
};


@interface AudioWaveformLoader ()

- (nullable AudioFileHandle *)openFileAtPath:(NSString *)filename
                                    pass:(struct VibeWaveformDecodePass *)pass;

- (std::unique_ptr<wavecore::SummaryBuilder>)builderForPass:(struct VibeWaveformDecodePass *)pass
                                                 sampleRate:(double)sampleRate;

// How far short of its claimed length a decode may end and still count as
// complete: a VBR mis-tag or slight truncation over-reports the length.
+ (AVAudioFramePosition)shortfallToleranceForFrames:(AVAudioFramePosition)totalFrames;

- (BOOL)isDecodeComplete:(struct VibeWaveformDecodePass *)pass filename:(NSString *)filename;

@end

NS_ASSUME_NONNULL_END

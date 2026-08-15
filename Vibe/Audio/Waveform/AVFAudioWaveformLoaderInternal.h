//
//  AVFAudioWaveformLoaderInternal.h
//  Vibe
//
//  The decode pass's phases, declared so the tests can reach them one at a
//  time. The completeness rule and the short-file stretch read the pass struct
//  and need no audio at all, which is the point: a file that decodes one chunk
//  short looks identical on screen, so nothing but an assertion catches it.
//
//  Do not use this outside AVFAudioWaveformLoader.mm and its tests.
//

#import "AVFAudioWaveformLoader.h"
#import "AudioWaveform.h"
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// What the decode pass is told and what it reports back: a fact about the
// file, settled before the loop starts, or a fact about how far the loop got,
// which every later phase reads.
struct VibeWaveformDecodePass {
    // In: the file's shape, and how many chunks this decode will actually fill
    // (fewer than the waveform's array only for a file shorter than that).
    AVAudioFramePosition totalFrames;
    NSUInteger numChannels;
    NSUInteger effectiveChunks;
    // Out: how far it got, and whether it stopped because a read failed.
    NSUInteger chunksFilled;
    AVAudioFramePosition framesRead;
    BOOL readError;
};

@interface AVFAudioWaveformLoader ()

- (nullable AVAudioFile *)openFileAtPath:(NSString *)filename
                                    pass:(struct VibeWaveformDecodePass *)pass;

// Both out-parameters are written only on success.
- (nullable CodableAudioWaveform *)makeWaveformForPass:(struct VibeWaveformDecodePass *)pass
                                              waveform:(AudioWaveform * _Nonnull * _Nonnull)outWaveform
                                             numChunks:(NSUInteger *)outNumChunks;

- (BOOL)isDecodeComplete:(struct VibeWaveformDecodePass *)pass filename:(NSString *)filename;

- (void)stretchWaveform:(AudioWaveform *)waveform
                   pass:(struct VibeWaveformDecodePass *)pass
              numChunks:(NSUInteger)numChunks;

@end

NS_ASSUME_NONNULL_END

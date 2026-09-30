//
//  AudioFileFormat.m
//  Vibe
//

#import "AudioFileFormat.h"

VibeAudioFileFormat const VibeAudioFileFormatMP3 = @"MP3";
VibeAudioFileFormat const VibeAudioFileFormatMP2 = @"MP2";
VibeAudioFileFormat const VibeAudioFileFormatAAC = @"AAC";
VibeAudioFileFormat const VibeAudioFileFormatFLAC = @"FLAC";
VibeAudioFileFormat const VibeAudioFileFormatMP4 = @"MP4";
VibeAudioFileFormat const VibeAudioFileFormatALAC = @"ALAC";
VibeAudioFileFormat const VibeAudioFileFormatAIFF = @"AIFF";
VibeAudioFileFormat const VibeAudioFileFormatWAV = @"WAV";
VibeAudioFileFormat const VibeAudioFileFormatW64 = @"W64";
VibeAudioFileFormat const VibeAudioFileFormatCAF = @"CAF";
VibeAudioFileFormat const VibeAudioFileFormatVorbis = @"Vorbis";
VibeAudioFileFormat const VibeAudioFileFormatOpus = @"Opus";

VibeAudioFileFormat _Nullable VibeAudioFileFormatForCodec(AudioFormatID codec) {
    switch (codec) {
        case kAudioFormatMPEGLayer3:    return VibeAudioFileFormatMP3;
        case kAudioFormatMPEGLayer2:    return VibeAudioFileFormatMP2;
        case kAudioFormatMPEG4AAC:      return VibeAudioFileFormatAAC;
        case kAudioFormatFLAC:          return VibeAudioFileFormatFLAC;
        case kAudioFormatAppleLossless: return VibeAudioFileFormatALAC;
        case kAudioFormatOpus:          return VibeAudioFileFormatOpus;
        case 'vorb':                    return VibeAudioFileFormatVorbis; // the SDK names no constant
        default:                        return nil;
    }
}

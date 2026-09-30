//
//  AudioFileFormat.h
//  Vibe
//
//  Sniffed codec/container names shared by metadata display and conversion.
//

#import <Foundation/Foundation.h>
#import <CoreAudioTypes/CoreAudioTypes.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString *VibeAudioFileFormat NS_TYPED_EXTENSIBLE_ENUM;

FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatMP3;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatMP2;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatAAC;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatFLAC;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatMP4;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatALAC;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatAIFF;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatWAV;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatW64;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatCAF;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatVorbis;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatOpus;

// The codec's name, or nil for one without a constant here (PCM among them:
// its name is its container's).
FOUNDATION_EXPORT VibeAudioFileFormat _Nullable VibeAudioFileFormatForCodec(AudioFormatID codec);

NS_ASSUME_NONNULL_END

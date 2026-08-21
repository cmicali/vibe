//
//  AudioFileFormat.h
//  Vibe
//
//  Sniffed codec/container names shared by metadata display and conversion.
//

#import <Foundation/Foundation.h>

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

NS_ASSUME_NONNULL_END

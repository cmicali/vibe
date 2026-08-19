//
//  FLACConvertRules.h
//  Vibe
//
//  The Convert to FLAC eligibility and naming rules: pure functions of their
//  inputs — no track, no file system, no controller.
//

#import <Foundation/Foundation.h>

#import "AudioFileFormat.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibeUncompressedContainer) {
    VibeUncompressedContainerUnknown = 0,
    VibeUncompressedContainerWAV,
    VibeUncompressedContainerAIFF,
};

// The extensions of the uncompressed containers Vibe accepts. .wave and .bwf
// are in because the claimed UTType declares all three RIFF WAVE spellings.
// .aifc is left out: it may hold compressed audio and needs a sniffed type.
static inline VibeUncompressedContainer VibeUncompressedContainerForExtension(
        NSString *_Nullable ext) {
    NSString *e = ext.lowercaseString;
    if ([e isEqualToString:@"wav"] || [e isEqualToString:@"wave"] ||
            [e isEqualToString:@"bwf"]) {
        return VibeUncompressedContainerWAV;
    }
    if ([e isEqualToString:@"aif"] || [e isEqualToString:@"aiff"]) {
        return VibeUncompressedContainerAIFF;
    }
    return VibeUncompressedContainerUnknown;
}

static inline BOOL VibeExtensionIsUncompressed(NSString *_Nullable ext) {
    return VibeUncompressedContainerForExtension(ext) != VibeUncompressedContainerUnknown;
}

// Preliminary eligibility for menus and direct requests. The cached sniffed
// type wins when present; while metadata is pending, the extension keeps a
// fresh row enabled. Conversion still performs a mandatory header sniff.
static inline VibeUncompressedContainer VibeUncompressedContainerForFile(
        VibeAudioFileFormat _Nullable fileType, NSString *_Nullable ext) {
    if (fileType.length > 0) {
        if ([fileType isEqualToString:VibeAudioFileFormatWAV]) {
            return VibeUncompressedContainerWAV;
        }
        if ([fileType isEqualToString:VibeAudioFileFormatAIFF]) {
            return VibeUncompressedContainerAIFF;
        }
        return VibeUncompressedContainerUnknown;
    }
    return VibeUncompressedContainerForExtension(ext);
}

// True for the uncompressed containers only — anything else gains nothing.
// The sniffed fileType wins when present. It is nil until the background scan
// reaches a track, and the extension covers that window so fresh rows are not
// disabled; it is never the converter's final content check.
static inline BOOL VibeTrackIsConvertibleToFLAC(VibeAudioFileFormat _Nullable fileType,
                                                NSString *_Nullable ext) {
    return VibeUncompressedContainerForFile(fileType, ext) != VibeUncompressedContainerUnknown;
}

// The FLAC that would sit beside the source: foo.wav becomes foo.flac, and a
// dotted basename keeps every component but the last one.
static inline NSString *VibeFLACDestinationName(NSString *sourceLastPathComponent) {
    NSString *base = sourceLastPathComponent.stringByDeletingPathExtension;
    // A dotfile has no extension to delete, and appending to an empty string
    // would yield a bare ".flac" that collides with every other conversion in
    // the folder.
    if (base.length == 0) {
        base = sourceLastPathComponent;
    }
    NSString *destination = [base stringByAppendingPathExtension:@"flac"];
    return destination ?: [base stringByAppendingString:@".flac"];
}

NS_ASSUME_NONNULL_END

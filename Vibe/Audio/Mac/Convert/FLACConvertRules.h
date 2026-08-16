//
//  FLACConvertRules.h
//  Vibe
//
//  The Convert to FLAC eligibility and naming rules: pure functions of their
//  inputs — no track, no file system, no controller.
//

#import <Foundation/Foundation.h>

#import "AudioTrackMetadata.h"

NS_ASSUME_NONNULL_BEGIN

// The extensions of the uncompressed containers Vibe accepts. .wave and .bwf
// are in because the claimed UTType (com.microsoft.waveform-audio) declares
// all three spellings — they are plain RIFF WAVE — and the open filter
// (NSURLUtil.supportedExtensions) admits them too. .aifc is left out: AIFF-C
// carries a compression type and may hold anything, so it is only ever
// eligible once TagLib has classified it as FILETYPE_AIFF.
static inline BOOL VibeExtensionIsUncompressed(NSString *_Nullable ext) {
    NSString *e = ext.lowercaseString;
    return [e isEqualToString:@"wav"] || [e isEqualToString:@"wave"] || [e isEqualToString:@"bwf"] ||
           [e isEqualToString:@"aif"] || [e isEqualToString:@"aiff"];
}

// True for the uncompressed containers only — anything else gains nothing.
// The sniffed fileType wins when present, because an extension can lie and
// TagLib read the bytes; it is nil until the background scan reaches a track,
// and the extension covers that window so fresh rows are not disabled.
static inline BOOL VibeTrackIsConvertibleToFLAC(NSString *_Nullable fileType,
                                                NSString *_Nullable ext) {
    if (fileType.length > 0) {
        return [fileType isEqualToString:FILETYPE_WAV] || [fileType isEqualToString:FILETYPE_AIFF];
    }
    return VibeExtensionIsUncompressed(ext);
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

//
//  PlayableExtensions.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Every audio extension Vibe plays. Foundation-only so both readers can import
// it: NSURLUtil imports PlaylistFile, so neither could own the set.
//
// Must cover every spelling CFBundleDocumentTypes admits, conformance
// included (com.microsoft.waveform-audio is wav, wave AND bwf;
// public.mpeg-4-audio takes in the m4r ringtone, public.aac-audio adts), or
// Finder offers Vibe a file the open filter silently discards.
@interface PlayableExtensions : NSObject

// Lowercase, lossless before lossy: a playlist entry naming a missing file
// takes the first spelling that exists, so the order picks the replacement.
@property (class, readonly) NSArray<NSString *> *ordered;

@property (class, readonly) NSSet<NSString *> *lookup;

// The playable ones TagLib parses (AudioTrackMetadata.mm's openByExtension,
// adts by its content). The rest — w64, caf — take their facts from
// CoreAudio, which reads only a whole local file.
@property (class, readonly) NSSet<NSString *> *tagParsed;

@end

NS_ASSUME_NONNULL_END

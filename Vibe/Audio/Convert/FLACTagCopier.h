//
//  FLACTagCopier.h
//  Vibe
//
//  Carries a WAV or AIFF file's tags and cover art over to the FLAC that
//  Convert to FLAC just encoded from it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// C linkage: the implementation is ObjC++ (TagLib), the caller plain ObjC.
#ifdef __cplusplus
extern "C" {
#endif

// Copies the scalar tags and the front-cover art from sourcePath's ID3v2 tag
// into flacPath's Vorbis comments and picture blocks, and saves. Returns NO
// when nothing could be copied — cosmetic, not fatal: every display path
// falls back to the filename. A free function so the TagLib include graph
// stays inside the .mm.
BOOL VibeCopyTagsToFLAC(NSString *sourcePath, NSString *flacPath);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

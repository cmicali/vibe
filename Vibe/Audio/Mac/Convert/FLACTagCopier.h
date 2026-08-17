//
//  FLACTagCopier.h
//  Vibe
//
//  Carries a WAV or AIFF file's tags and embedded art over to the FLAC that
//  Convert to FLAC just encoded from it.
//

#import <Foundation/Foundation.h>
#import "FLACConvertRules.h"

NS_ASSUME_NONNULL_BEGIN

// C linkage: the implementation is ObjC++ (TagLib), the caller plain ObjC.
#ifdef __cplusplus
extern "C" {
#endif

// Reads the RIFF/FORM header rather than trusting the extension or cached
// metadata. Unknown means conversion must stop before replacing the source.
VibeUncompressedContainer VibeSniffUncompressedContainer(NSString *sourcePath);

// Copies the scalar tags and front-cover picture into the FLAC and saves it.
// The source is revalidated against sourceContainer so a file changed during
// conversion cannot be opened through the wrong reader. NO means conversion
// must fail rather than discard metadata. Free functions keep the TagLib
// include graph inside the .mm.
BOOL VibeCopyTagsToFLAC(NSString *sourcePath, NSString *flacPath,
                       VibeUncompressedContainer sourceContainer);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

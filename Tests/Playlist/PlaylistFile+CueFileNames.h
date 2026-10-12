//
//  PlaylistFile+CueFileNames.h
//
//  A test helper, implemented in PlaylistFileTests.m and shared with
//  PlaylistFileFuzzTests.m.
//

#import "PlaylistFile.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlaylistFile (CueFileNames)

// The FILE names a sheet resolves, in resolution order: the FILE-line lexing,
// read through the one CUE reader.
+ (NSArray<NSString *> *)fileNamesInCueText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END

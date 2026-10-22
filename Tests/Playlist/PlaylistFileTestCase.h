//
//  PlaylistFileTestCase.h
//  VibeTests
//
//  The harness the PlaylistFile tests share: a temp folder of empty files
//  beside a playlist, and the FILE names a sheet resolves. It runs no tests.
//  PlaylistFileTests and PlaylistFileCUETests subclass it.
//

#import <XCTest/XCTest.h>
#import "PlaylistFile.h"

NS_ASSUME_NONNULL_BEGIN

// The FILE names a sheet resolves, in resolution order: the FILE-line lexing,
// read through the one CUE reader.
@interface PlaylistFile (CueFileNames)
+ (NSArray<NSString *> *)fileNamesInCueText:(NSString *)text;
@end

@interface PlaylistFileTestCase : XCTestCase
- (NSURL *)makeTempDirWithFiles:(NSArray<NSString *> *)names
                   playlistName:(NSString *)playlistName
                           text:(NSString *)text;
@end

NS_ASSUME_NONNULL_END

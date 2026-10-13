//
//  PlaylistFileTestCase.h
//  VibeTests
//
//  The harness the PlaylistFile tests share: a temp folder of empty files
//  beside a playlist, a cue row built from its fields, and the FILE names a
//  sheet resolves. It runs no tests. PlaylistFileTests, PlaylistFileCUETests
//  and PlaylistFileSessionTests subclass it.
//

#import <XCTest/XCTest.h>
#import "AudioTrack.h"
#import "PlaylistFile.h"

NS_ASSUME_NONNULL_BEGIN

static inline AudioTrack *CueRowAt(NSString *path, NSUInteger start, NSUInteger end, NSString *_Nullable title,
                                   NSString *_Nullable performer, NSString *_Nullable sheet, NSInteger number) {
    return [[AudioTrack alloc] initWithURL:[NSURL fileURLWithPath:path] cueStart:start cueEnd:end
                                     title:title performer:performer
                                     sheet:sheet ? [NSURL fileURLWithPath:sheet] : nil trackNumber:number];
}

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

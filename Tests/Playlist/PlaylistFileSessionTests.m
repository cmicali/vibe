//
//  PlaylistFileSessionTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "PlaylistFile.h"
#import "PlaylistFile+Session.h"
#import "AudioTrack.h"
#import "TestFilesystemGuard.h"

@interface PlaylistFileSessionTests : XCTestCase
@end

@implementation PlaylistFileSessionTests

#pragma mark - Private session mirror

- (NSURL *)sessionURLWithDefaults:(NSUserDefaults **)defaults {
    NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                   [@"vibe-session-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    // TRAP: use the in-memory store. cfprefsd can cache stale values and
    // write a named suite into the real Preferences directory after exit.
    *defaults = [[VibeTestUserDefaults alloc]
                 initWithSuiteName:[root.path stringByAppendingPathComponent:@"defaults"]];
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    }];
    return [root URLByAppendingPathComponent:@"nested/session.m3u"];
}

- (NSArray<AudioTrack *> *)sessionTracks {
    // These paths deliberately do not exist: restoring the mirror never probes audio files.
    AudioTrack *a = [AudioTrack withURL:[NSURL fileURLWithPath:@"/nonexistent-vibe-session/a.mp3"]];
    AudioTrack *b = [AudioTrack withURL:[NSURL fileURLWithPath:@"/nonexistent-vibe-session/b.flac"]];
    return @[a, b, a];
}

- (void)testSessionRoundTripPreservesOrderDuplicatesCursorAndPausedIntent {
    NSUserDefaults *defaults;
    NSURL *url = [self sessionURLWithDefaults:&defaults];
    NSArray *tracks = self.sessionTracks;
    NSError *error = nil;
    XCTAssertTrue([PlaylistFile saveSessionTracks:tracks currentIndex:1 enabled:YES toURL:url defaults:defaults write:nil error:&error]);
    XCTAssertNil(error);
    __block NSUInteger loads = 0;
    XCTAssertTrue([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:^(NSArray<AudioTrack *> *rows, NSUInteger index, BOOL paused) {
        loads++;
        XCTAssertEqualObjects([rows valueForKey:@"url"], [tracks valueForKey:@"url"]);
        XCTAssertEqual(index, 1u);
        XCTAssertTrue(paused);
    }]);
    XCTAssertEqual(loads, 1u);
}

- (void)testSessionCursorClampsCorruptAndOutOfRangeValues {
    NSUserDefaults *defaults;
    NSURL *url = [self sessionURLWithDefaults:&defaults];
    XCTAssertTrue([PlaylistFile saveSessionTracks:self.sessionTracks currentIndex:NSNotFound enabled:YES toURL:url defaults:defaults write:nil error:nil]);
    XCTAssertEqual([defaults integerForKey:kVibeLastPlaylistCurrentIndexKey], 2);
    for (NSArray<NSNumber *> *row in @[@[@(-4), @0], @[@0, @0], @[@1, @1], @[@(NSIntegerMax), @2]]) {
        [defaults setObject:row[0] forKey:kVibeLastPlaylistCurrentIndexKey];
        XCTAssertTrue([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:^(NSArray *urls, NSUInteger index, BOOL paused) {
            XCTAssertEqual(index, row[1].unsignedIntegerValue);
        }]);
    }
    [defaults removeObjectForKey:kVibeLastPlaylistCurrentIndexKey];
    XCTAssertTrue([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:^(NSArray *urls, NSUInteger index, BOOL paused) {
        XCTAssertEqual(index, 0u);
    }]);
}

- (void)testFailedSaveRemovesOldMirrorAndCursor {
    NSUserDefaults *defaults;
    NSURL *url = [self sessionURLWithDefaults:&defaults];
    XCTAssertTrue([PlaylistFile saveSessionTracks:self.sessionTracks currentIndex:1 enabled:YES toURL:url defaults:defaults write:nil error:nil]);
    NSError *failure = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:nil];
    NSError *error = nil;
    XCTAssertFalse([PlaylistFile saveSessionTracks:self.sessionTracks currentIndex:2 enabled:YES toURL:url defaults:defaults write:^BOOL(NSError **outError) {
        if (outError) *outError = failure;
        return NO;
    } error:&error]);
    XCTAssertEqualObjects(error, failure);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:url.path]);
    XCTAssertNil([defaults objectForKey:kVibeLastPlaylistCurrentIndexKey]);
    XCTAssertFalse([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:^(NSArray *urls, NSUInteger index, BOOL paused) {
        XCTFail(@"Must not revive an old playlist after failed save");
    }]);
}

- (void)testDisabledOrEmptySaveDeletesSessionWithoutCallingWriter {
    for (NSNumber *enabled in @[@NO, @YES]) {
        NSUserDefaults *defaults;
        NSURL *url = [self sessionURLWithDefaults:&defaults];
        XCTAssertTrue([PlaylistFile saveSessionTracks:self.sessionTracks currentIndex:1 enabled:YES toURL:url defaults:defaults write:nil error:nil]);
        NSArray *tracks = enabled.boolValue ? @[] : self.sessionTracks;
        XCTAssertTrue([PlaylistFile saveSessionTracks:tracks currentIndex:0 enabled:enabled.boolValue toURL:url defaults:defaults write:^BOOL(NSError **error) {
            XCTFail(@"No session should be written"); return YES;
        } error:nil]);
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:url.path]);
        XCTAssertNil([defaults objectForKey:kVibeLastPlaylistCurrentIndexKey]);
    }
}

- (void)testDisabledOrUnusableMirrorNeverLoads {
    NSUserDefaults *defaults;
    NSURL *url = [self sessionURLWithDefaults:&defaults];
    void (^unexpectedLoad)(NSArray *, NSUInteger, BOOL) = ^(NSArray *urls, NSUInteger index, BOOL paused) { XCTFail(@"No restorable session"); };
    XCTAssertFalse([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:unexpectedLoad]);
    XCTAssertTrue([PlaylistFile saveSessionTracks:self.sessionTracks currentIndex:0 enabled:YES toURL:url defaults:defaults write:nil error:nil]);
    XCTAssertFalse([PlaylistFile restoreSessionAtURL:url enabled:NO defaults:defaults load:unexpectedLoad]);
    for (NSString *text in @[@"", @"#EXTM3U\n# comment\n", @"relative.mp3\nhttps://example.com/a.mp3\n"]) {
        XCTAssertTrue([text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        XCTAssertFalse([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:unexpectedLoad]);
    }
}

#pragma mark - Cue rows in the session

static AudioTrack *CueRowAt(NSString *path, NSUInteger start, NSUInteger end, NSString *title,
                            NSString *performer, NSString *sheet, NSInteger number) {
    return [[AudioTrack alloc] initWithURL:[NSURL fileURLWithPath:path] cueStart:start cueEnd:end
                                     title:title performer:performer sheet:[NSURL fileURLWithPath:sheet]
                               trackNumber:number];
}

static void AssertSameRow(AudioTrack *restored, AudioTrack *saved) {
    XCTAssertEqualObjects(restored.url.path, saved.url.path);
    XCTAssertEqual(restored.cueStart, saved.cueStart);
    XCTAssertEqual(restored.cueEnd, saved.cueEnd);
    XCTAssertEqualObjects(restored.cueTitle, saved.cueTitle);
    XCTAssertEqualObjects(restored.cuePerformer, saved.cuePerformer);
    XCTAssertEqualObjects(restored.cueSheetURL.path, saved.cueSheetURL.path);
    XCTAssertEqual(restored.cueTrackNumber, saved.cueTrackNumber);
}

- (void)testSessionRoundTripRestoresCueRowsExactly {
    NSUserDefaults *defaults;
    NSURL *url = [self sessionURLWithDefaults:&defaults];
    NSString *sheet = @"/nonexistent-vibe-session/Mix, Vol. 1.cue";
    NSArray<AudioTrack *> *tracks = @[
        [AudioTrack withURL:[NSURL fileURLWithPath:@"/nonexistent-vibe-session/a.mp3"]],
        CueRowAt(@"/nonexistent-vibe-session/mix.flac", 0, 4500, @"One, the first", @"DJ 100% & co", sheet, 1),
        CueRowAt(@"/nonexistent-vibe-session/mix.flac", 4500, 0, @"Two\nlines", nil, sheet, 2),
        CueRowAt(@"/nonexistent-vibe-session/single.flac", 0, 0, @"Whole", @"Band", sheet, 7),
    ];
    XCTAssertTrue([PlaylistFile saveSessionTracks:tracks currentIndex:2 enabled:YES toURL:url defaults:defaults
                                            write:nil error:nil]);
    __block NSArray<AudioTrack *> *restored = nil;
    XCTAssertTrue([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults
                                               load:^(NSArray<AudioTrack *> *rows, NSUInteger index, BOOL paused) {
        restored = rows;
        XCTAssertEqual(index, 2u);
    }]);
    XCTAssertEqual(restored.count, tracks.count);
    for (NSUInteger i = 0; i < MIN(restored.count, tracks.count); i++) {
        AssertSameRow(restored[i], tracks[i]);
    }
    XCTAssertFalse(restored[0].isWindowed);
    XCTAssertNil(restored[0].cueSheetURL);
}

@end

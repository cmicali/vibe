//
//  AudioTrackTagTests.mm
//  VibeAudioTests
//
//  The row over the real tag parse: a tagged tempo and key beat analysis, and
//  a tagged FLAC's embedded sheet still makes rows. The files come from the
//  metadata tests' AudioTrackMetadataTagFixtures.h.
//

#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioTrackMetadataTagFixtures.h"
#import "PlaylistFile.h"

@interface AudioTrackTagTests : XCTestCase
@end

@implementation AudioTrackTagTests {
    NSURL *_dir;
    NSData *_art;
}

- (void)setUp {
    [super setUp];
    _dir = VibeTagFixtureDirectory();
    _art = VibeImageOfColor(300, 0.8, 0.2, 0.3, NO);
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

- (AudioTrackMetadata *)parse:(VibeTagFixture)fixture {
    NSURL *url = VibeWriteTagFixture(_dir, fixture, VibeTagFixtureHasArt(fixture) ? _art : nil, NULL);
    XCTAssertNotNil(url, @"%@", VibeTagFixtureName(fixture));
    return [AudioTrackMetadata metadataWithURL:url displayArtData:NULL];
}

- (void)testATaggedTempoAndKeyBeatAnalysis {
    AudioTrackMetadata *tagged = [self parse:VibeTagFixtureFLAC];
    AudioTrackMetadata *untagged = [self parse:VibeTagFixtureWAVInfo];
    for (AudioTrackMetadata *metadata in @[tagged, untagged]) {
        AudioTrack *track = [[AudioTrack alloc] initWithURL:_dir];
        track.detectedBPM = 90;
        track.detectedKey = VibeMusicalKeyMake(0, NO);
        XCTAssertTrue([track installMetadataIfUnresolved:metadata]);
        BOOL isTagged = metadata == tagged;
        XCTAssertEqual(track.bpm, isTagged ? kVibeTagBPM : 90.0f);
        XCTAssertEqual(track.key, isTagged ? VibeMusicalKeyMake(9, YES) : VibeMusicalKeyMake(0, NO));
    }
}

// TagLib's save keeps the CUESHEET block, so the file still plays as rows.
- (void)testATaggedFLACsEmbeddedCueSheetStillMakesRows {
    XCTAssertTrue([self parse:VibeTagFixtureFLACCueSheet].parsedOK);
    NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:[PlaylistFile cueEntriesEmbeddedInFLACAtURL:
            [_dir URLByAppendingPathComponent:@"cuesheet.flac"]]];
    XCTAssertEqual(rows.count, 2u);
}

@end

//
// The five art accessors and the one rule they all apply: a file's own artwork
// always wins, "unknown" is never "artless", and the folder's cover is a
// display-time fallback that must never reach the disk cache.
//

#import <XCTest/XCTest.h>

#import "AudioTrackArtwork.h"
#import "FolderArtResolver.h"
#import "NSImage+Util.h"

@interface AudioTrackArtworkTests : XCTestCase
@end

@implementation AudioTrackArtworkTests {
    NSImage *_folderCover;
    NSString *_directory;
    NSString *_trackPath;
}

- (void)setUp {
    _folderCover = [[NSImage alloc] initWithSize:NSMakeSize(4, 4)];
    _directory = @"/Library/Albums/Precedence";
    _trackPath = [_directory stringByAppendingPathComponent:@"track.mp3"];
}

// A resolver that always has a cover for the directory, so any folder lookup
// this class makes is visible in the result.
- (FolderArtResolver *)resolverWithCover {
    FolderArtResolver *resolver = [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
        return YES;
    } accessProvider:^BOOL(NSString *directory) {
        return YES;
    } lister:^NSArray<NSString *> *(NSString *directory) {
        return @[@"cover.jpg"];
    } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return YES;
    } dataReader:^NSData *(NSString *path) {
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return self->_folderCover;
    }];
    [resolver noteListedDirectories:[NSSet setWithObject:_directory]
             artFilenameByDirectory:@{_directory: @"cover.jpg"}];
    return resolver;
}

// Real PNG bytes, so the class's own ImageIO decode succeeds and the result is
// distinguishable from the folder cover by size.
- (NSData *)embeddedArtData {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(8, 8)];
    [image lockFocus];
    [NSColor.blueColor setFill];
    NSRectFill(NSMakeRect(0, 0, 8, 8));
    [image unlockFocus];
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:image.TIFFRepresentation];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

- (AudioTrackArtwork *)artworkWithExtractor:(AudioTrackArtworkExtractor)extractor {
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:_trackPath
                                                                        extractor:extractor];
    artwork.folderArt = [self resolverWithCover];
    return artwork;
}

#pragma mark - The file's own art wins

- (void)testEmbeddedArtBeatsTheFoldersCover {
    NSData *embedded = [self embeddedArtData];
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^NSData *(NSString *path) {
        return embedded;
    }];
    NSImage *art = [artwork loadArtBlocking];
    XCTAssertNotNil(art);
    XCTAssertNotEqualObjects(art, _folderCover);
    XCTAssertNotEqualObjects(artwork.cachedThumbnail, _folderCover);
}

// The window before a file's own art has been read is NOT the artless answer.
// Getting this wrong puts a folder cover in front of a track's own artwork.
- (void)testAnUnreadFileNeverFallsBackToTheFolder {
    __block BOOL extracted = NO;
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:_trackPath
                                                                        extractor:^NSData *(NSString *path) {
        extracted = YES;
        return nil;
    }];
    artwork.folderArt = [self resolverWithCover];
    // Non-blocking accessors must not answer with the folder while the file's
    // own art is merely unknown.
    XCTAssertNil(artwork.cachedArt);
    XCTAssertNil(artwork.cachedThumbnail);
    XCTAssertFalse(extracted, @"neither accessor may read the audio file");
}

- (void)testTheFolderAnswersOnlyOnceTheFileIsKnownArtless {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^NSData *(NSString *path) {
        return nil; // the file really has none
    }];
    // The blocking accessor settles the question and then falls back.
    XCTAssertEqualObjects([artwork loadArtBlocking], _folderCover);
    // And the non-blocking ones follow, now that the answer is known.
    XCTAssertEqualObjects(artwork.cachedArt, _folderCover);
}

- (void)testUndecodableOwnArtFallsBackToTheFolder {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^NSData *(NSString *path) {
        return [@"not an image" dataUsingEncoding:NSUTF8StringEncoding];
    }];
    XCTAssertEqualObjects([artwork loadArtBlocking], _folderCover);
}

#pragma mark - The cache boundary

// The disk cache is keyed by the AUDIO file's size and mtime, which a sidecar
// image cannot move: an archived cover would outlive its file, and an archived
// "artless" would suppress the lookup forever. So the archive's thumbnail is
// the file's own art or nothing, whatever the folder holds.
- (void)testTheArchivableThumbnailIsNeverTheFoldersCover {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^NSData *(NSString *path) {
        return nil;
    }];
    XCTAssertEqualObjects([artwork loadArtBlocking], _folderCover, @"precondition: the folder has one");
    XCTAssertNil(artwork.embeddedThumbnail);
}

- (void)testTheArchivableThumbnailIsTheFilesOwnArtWhenItHasSome {
    NSData *embedded = [self embeddedArtData];
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^NSData *(NSString *path) {
        return embedded;
    }];
    (void)[artwork loadArtBlocking]; // decode it
    XCTAssertNotNil(artwork.embeddedThumbnail);
    XCTAssertNotEqualObjects(artwork.embeddedThumbnail, _folderCover);
}

// The metadata scan calls this before publishing a row. It must warm the
// file's own thumbnail WITHOUT resolving folder art, or a playlist scan turns
// into a folder-art storm across every artless row.
- (void)testThePrewarmNeverTouchesTheFolder {
    __block NSUInteger folderLookups = 0;
    FolderArtResolver *counting = [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
        return YES;
    } accessProvider:^BOOL(NSString *directory) {
        folderLookups++;
        return YES;
    } lister:^NSArray<NSString *> *(NSString *directory) {
        folderLookups++;
        return @[@"cover.jpg"];
    } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
        folderLookups++;
        return YES;
    } dataReader:^NSData *(NSString *path) {
        folderLookups++;
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return self->_folderCover;
    }];
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:_trackPath
                                                                        extractor:^NSData *(NSString *path) {
        return nil; // artless: the row most likely to reach for a cover
    }];
    artwork.folderArt = counting;

    [artwork prewarmEmbeddedThumbnail];

    XCTAssertEqual(folderLookups, 0u);
}

#pragma mark - Cache-hit instances

// A cache hit carries the archived thumbnail and no art bytes. An entry that
// archived no thumbnail was artless, so it may use the folder's cover without
// re-reading the audio file.
- (void)testACacheHitWithoutAThumbnailIsArtlessAndUsesTheFolder {
    __block BOOL extracted = NO;
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:_trackPath
                                                                        extractor:^NSData *(NSString *path) {
        extracted = YES;
        return nil;
    }];
    artwork.folderArt = [self resolverWithCover];
    [artwork adoptArchivedThumbnailJPEG:nil];

    XCTAssertEqualObjects([artwork loadArtBlocking], _folderCover);
    XCTAssertFalse(extracted, @"an archived artless entry must not re-parse the file");
}

// The row accessor is non-blocking on purpose — a playlist cell calls it while
// drawing — so it answers nil until a background resolve has produced the
// thumbnail, rather than reading and decoding a cover on the main thread.
- (void)testTheRowAccessorNeverBlocksForAnUnresolvedFolder {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^NSData *(NSString *path) {
        return nil;
    }];
    [artwork adoptArchivedThumbnailJPEG:nil];

    XCTAssertNil(artwork.cachedThumbnail, @"nothing is decoded yet, so nothing to hand back");

    // It scheduled the resolve, so the cover appears without anyone blocking.
    NSPredicate *resolved = [NSPredicate predicateWithBlock:^BOOL(AudioTrackArtwork *subject, id _) {
        return [subject.cachedThumbnail isEqual:self->_folderCover];
    }];
    [self expectationForPredicate:resolved evaluatedWithObject:artwork handler:nil];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];
}

- (void)testACacheHitWithAThumbnailKeepsItsOwn {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^NSData *(NSString *path) {
        return nil;
    }];
    [artwork adoptArchivedThumbnailJPEG:[self embeddedArtData]];
    NSImage *thumbnail = artwork.cachedThumbnail;
    XCTAssertNotNil(thumbnail);
    XCTAssertNotEqualObjects(thumbnail, _folderCover);
}

@end

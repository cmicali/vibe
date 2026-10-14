
#import <XCTest/XCTest.h>

#import "DropboxLinkRules.h"
#import "FilePaths.h"
#import "LinkRules.h"
#import "LinkStoreTestCase.h"
#import "PlaylistFile.h"
#import "VibeFakeHTTPProtocol.h"

static NSString *const kFolderLink = @"https://www.dropbox.com/scl/fo/key1/hash1?rlkey=rk&dl=0";
static NSString *const kFolderPath = @"/scl/fo/key1/hash1";
static NSString *const kListingPath = @"/list_shared_link_folder_entries";

// A listing's file entry as the share page gets it. path is below the share's
// root. Its href carries the page's st, which no link keeps.
static NSDictionary *ListedFile(NSString *path, long long bytes, NSNumber *ts) {
    NSURLComponents *href = [NSURLComponents componentsWithString:@"https://www.dropbox.com"];
    href.path = [NSString stringWithFormat:@"%@/%@", kFolderPath, path];
    href.query = @"rlkey=rk&dl=0&st=page1";
    NSMutableDictionary *entry = [@{@"filename": path.lastPathComponent, @"bytes": @(bytes), @"is_dir": @NO,
                                    @"href": href.URL.absoluteString} mutableCopy];
    entry[@"ts"] = ts;
    return entry;
}

static NSDictionary *ListedFolder(NSString *path) {
    NSURLComponents *href = [NSURLComponents componentsWithString:@"https://www.dropbox.com"];
    href.path = [NSString stringWithFormat:@"%@/%@", kFolderPath, path];
    href.query = @"rlkey=rk&dl=0";
    return @{@"filename": path.lastPathComponent, @"is_dir": @YES, @"href": href.URL.absoluteString};
}

static NSData *ListingPage(NSArray<NSDictionary *> *entries, NSString *_Nullable voucher) {
    NSMutableDictionary *page = [@{@"entries": entries, @"has_more_entries": @(voucher != nil),
                                   @"folder": @{@"filename": @"Mix Tape"}} mutableCopy];
    page[@"next_request_voucher"] = voucher;
    return [NSJSONSerialization dataWithJSONObject:page options:0 error:NULL];
}

@interface DropboxLinkRulesTests : XCTestCase
@end

@implementation DropboxLinkRulesTests

- (void)testADropboxShareLinkGetsDLOne {
    NSDictionary<NSString *, NSString *> *cases = @{
        @"https://www.dropbox.com/scl/fi/abc123/Song.flac?rlkey=xyz&dl=0":
            @"https://www.dropbox.com/scl/fi/abc123/Song.flac?rlkey=xyz&dl=1",
        @"https://www.dropbox.com/scl/fi/abc123/Song.flac?dl=0&rlkey=xyz&st=q1":
            @"https://www.dropbox.com/scl/fi/abc123/Song.flac?rlkey=xyz&st=q1&dl=1",
        @"https://www.dropbox.com/scl/fi/abc123/Song.flac?rlkey=xyz":
            @"https://www.dropbox.com/scl/fi/abc123/Song.flac?rlkey=xyz&dl=1",
        @"https://dropbox.com/s/abc123/Song.mp3":
            @"https://dropbox.com/s/abc123/Song.mp3?dl=1",
        @"https://www.dropbox.com/s/abc123/Song.mp3?dl=1":
            @"https://www.dropbox.com/s/abc123/Song.mp3?dl=1",
        @"https://WWW.DROPBOX.COM/s/abc123/Song.mp3?dl=0":
            @"https://WWW.DROPBOX.COM/s/abc123/Song.mp3?dl=1",
        @"https://www.dropbox.com/s/abc123/Song.mp3?dl=0&dl=0":
            @"https://www.dropbox.com/s/abc123/Song.mp3?dl=1",
        @"https://www.dropbox.com/s/abc123/My%20Song.mp3?dl=0#frag":
            @"https://www.dropbox.com/s/abc123/My%20Song.mp3?dl=1#frag",
        @"https://www.dropbox.com/scl/fi/5b8vg9wzcs/122-Basti-Pieper-I-Love-You.aif?rlkey=iobgi14c49&dl=0":
            @"https://www.dropbox.com/scl/fi/5b8vg9wzcs/122-Basti-Pieper-I-Love-You.aif?rlkey=iobgi14c49&dl=1",
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSString *link, NSString *expected, BOOL *stop) {
        XCTAssertEqualObjects(VibeDropboxLinkDownloadURL([NSURL URLWithString:link]).absoluteString, expected, @"%@", link);
    }];
}

- (void)testAnythingButAFileShareLinkIsNotOne {
    for (NSString *string in @[@"https://www.dropbox.com/scl/fo/abc/folder?rlkey=x&dl=0",
                               @"https://www.dropbox.com/sh/abc/folder?dl=0",
                               @"https://www.dropbox.com/home/Music?dl=0",
                               @"https://www.dropbox.com/s",
                               @"https://www.dropbox.com/scl/fi",
                               @"https://dl.dropboxusercontent.com/s/abc/Song.mp3",
                               @"https://dropbox.com.evil.example/s/abc/Song.mp3?dl=0",
                               @"https://notdropbox.com/s/abc/Song.mp3?dl=0",
                               @"https://example.com/s/abc/Song.mp3?dl=0",
                               @"https://example.com/scl/fi/abc/Song.mp3?dl=0"]) {
        XCTAssertNil(VibeDropboxLinkDownloadURL([NSURL URLWithString:string]), @"%@", string);
    }
}

- (void)testAFolderLinkNamesItsShareToken {
    NSDictionary *token = VibeDropboxFolderLinkToken([NSURL URLWithString:
            @"https://www.dropbox.com/scl/fo/5mg7pqrbv84wtl9pkbiof/AJyld5XTOVekH-zoo_BvlLY?rlkey=lqkalyoo4r0da9wh23v0g1qtg&dl=0"]);
    XCTAssertEqualObjects(token, (@{@"linkKey": @"5mg7pqrbv84wtl9pkbiof", @"secureHash": @"AJyld5XTOVekH-zoo_BvlLY",
                                    @"linkType": @"c", @"subPath": @"", @"rlkey": @"lqkalyoo4r0da9wh23v0g1qtg"}));
    token = VibeDropboxFolderLinkToken([NSURL URLWithString:@"https://DROPBOX.com/scl/fo/k/h/Live%20Sets/2024?rlkey=r&st=x"]);
    XCTAssertEqualObjects(token[@"subPath"], @"Live Sets/2024");
    XCTAssertEqualObjects(token[@"linkKey"], @"k");
    token = VibeDropboxFolderLinkToken([NSURL URLWithString:@"https://www.dropbox.com/sh/abc123/AADxyz-_?dl=0"]);
    XCTAssertEqualObjects(token, (@{@"linkKey": @"abc123", @"secureHash": @"AADxyz-_", @"linkType": @"s",
                                    @"subPath": @""}));
}

- (void)testAnythingButAFolderLinkHasNoToken {
    for (NSString *string in @[@"https://www.dropbox.com/scl/fi/abc/Song.mp3?rlkey=x&dl=0",
                               @"https://www.dropbox.com/s/abc/Song.mp3?dl=0",
                               @"http://www.dropbox.com/scl/fo/k/h?rlkey=r",
                               @"https://www.dropbox.com/scl/fo/k",
                               @"https://www.dropbox.com/sh/k",
                               @"https://www.dropbox.com/scl/fo/k%2F/h?rlkey=r",
                               @"https://www.dropbox.com/scl/fo/k/h/a%2Fb?rlkey=r",
                               @"https://dropbox.com.evil.example/scl/fo/k/h?rlkey=r",
                               @"https://example.com/scl/fo/k/h?rlkey=r"]) {
        XCTAssertNil(VibeDropboxFolderLinkToken([NSURL URLWithString:string]), @"%@", string);
    }
}

- (void)testAFolderLinkIsKeptWithItsRlkeyAlone {
    NSDictionary *typed = VibeDropboxFolderLinkToken([NSURL URLWithString:@"https://dropbox.com/scl/fo/k/h?dl=1&rlkey=r&st=x"]);
    XCTAssertEqualObjects(VibeDropboxFolderLinkURL(typed).absoluteString, @"https://www.dropbox.com/scl/fo/k/h?rlkey=r");
    NSDictionary *sub = VibeDropboxFolderLinkToken([NSURL URLWithString:@"https://www.dropbox.com/scl/fo/k/h/Live%20Sets?rlkey=r"]);
    XCTAssertEqualObjects(VibeDropboxFolderLinkURL(sub).absoluteString,
                          @"https://www.dropbox.com/scl/fo/k/h/Live%20Sets?rlkey=r");
    NSDictionary *old = VibeDropboxFolderLinkToken([NSURL URLWithString:@"https://www.dropbox.com/sh/k/h?dl=0"]);
    XCTAssertEqualObjects(VibeDropboxFolderLinkURL(old).absoluteString, @"https://www.dropbox.com/sh/k/h");
}

- (void)testTheListingFormCarriesTheToken {
    NSDictionary *token = VibeDropboxFolderLinkToken([NSURL URLWithString:@"https://www.dropbox.com/scl/fo/k/h/A%20%26%20B?rlkey=r/1"]);
    NSString *first = [[NSString alloc] initWithData:VibeDropboxFolderListingBody(token, @"tok", nil)
                                            encoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects(first, @"is_xhr=true&link_key=k&link_type=c&secure_hash=h&sub_path=A%20%26%20B&rlkey=r%2F1&t=tok");
    NSString *next = [[NSString alloc] initWithData:VibeDropboxFolderListingBody(token, @"tok", @"v=2")
                                           encoding:NSUTF8StringEncoding];
    XCTAssertTrue([next hasSuffix:@"&voucher=v%3D2&t=tok"], @"%@", next);
}

- (void)testAListingPageReadsFilesAndFolders {
    NSDictionary *token = VibeDropboxFolderLinkToken([NSURL URLWithString:kFolderLink]);
    id answer = @{
        @"entries": @[
            ListedFile(@"Track One.flac", 4000, @1700000000),
            ListedFolder(@"Live"),
            @{@"filename": @"relative.mp3", @"bytes": @10, @"is_dir": @NO, @"href": @"/scl/fo/key1/hash1/relative.mp3"},
            @{@"filename": @"elsewhere.mp3", @"bytes": @10, @"is_dir": @NO, @"href": @"https://example.com/a.mp3"},
            @{@"filename": @"nosize.mp3", @"is_dir": @NO, @"href": @"/scl/fo/key1/hash1/nosize.mp3"},
            @{@"filename": @"Other", @"is_dir": @YES, @"href": @"/scl/fo/otherkey/hash1/Other"},
            @{@"filename": @"a/b.mp3", @"bytes": @10, @"is_dir": @NO, @"href": @"/scl/fo/key1/hash1/b.mp3"},
            @"not an entry",
        ],
        @"has_more_entries": @YES, @"next_request_voucher": @"v2", @"folder": @{@"filename": @"Mix Tape"},
    };
    NSString *voucher = nil;
    NSString *name = nil;
    NSArray<NSDictionary *> *entries = VibeDropboxFolderListingEntries(answer, token, &voucher, &name);
    XCTAssertEqual(entries.count, 3u, @"%@", entries);
    XCTAssertEqualObjects(entries[0][@"name"], @"Track One.flac");
    XCTAssertEqualObjects(entries[0][@"size"], @4000);
    XCTAssertEqualObjects(entries[0][@"modified"], @1700000000);
    XCTAssertEqualObjects([entries[0][@"url"] absoluteString],
                          @"https://www.dropbox.com/scl/fo/key1/hash1/Track%20One.flac?rlkey=rk&dl=1", @"no st");
    XCTAssertEqualObjects(entries[1][@"folder"][@"subPath"], @"Live");
    XCTAssertEqualObjects(entries[1][@"folder"][@"rlkey"], @"rk");
    XCTAssertEqualObjects([entries[2][@"url"] absoluteString],
                          @"https://www.dropbox.com/scl/fo/key1/hash1/relative.mp3?rlkey=rk&dl=1", @"the folder's rlkey");
    XCTAssertNil(entries[2][@"modified"]);
    XCTAssertEqualObjects(voucher, @"v2");
    XCTAssertEqualObjects(name, @"Mix Tape");

    NSMutableDictionary *last = [answer mutableCopy];
    last[@"has_more_entries"] = @NO;
    VibeDropboxFolderListingEntries(last, token, &voucher, NULL);
    XCTAssertNil(voucher, @"no more pages");
    XCTAssertNil(VibeDropboxFolderListingEntries(@{@"error": @"nope"}, token, &voucher, &name));
    XCTAssertNil(VibeDropboxFolderListingEntries(@[], token, NULL, NULL));
}

- (void)testTheShareLinkRewriteAsksThisFile {
    NSURL *link = [NSURL URLWithString:@"https://www.dropbox.com/s/abc123/Song.mp3?dl=0"];
    XCTAssertEqualObjects(VibeLinkDirectDownloadURL(link).absoluteString,
                          @"https://www.dropbox.com/s/abc123/Song.mp3?dl=1");
    NSURL *folder = [NSURL URLWithString:@"https://www.dropbox.com/sh/abc/folder?dl=0"];
    XCTAssertEqualObjects(VibeLinkDirectDownloadURL(folder), folder, @"fetched as typed");
}

@end

// A Dropbox link through the real LinkStore, over HTTPStub answering Dropbox's
// host.
@interface DropboxLinkStoreTests : LinkStoreTestCase
@end

@implementation DropboxLinkStoreTests

- (void)setUp {
    [super setUp];
    [_stub answerHost:@"www.dropbox.com"];
}

// The share page once, setting t, and the listing's pages in the order the
// folder's requests reach them.
- (void)queuePageAndListing:(NSArray<NSData *> *)pages {
    NSData *html = [@"<!doctype html><html></html>" dataUsingEncoding:NSUTF8StringEncoding];
    [_stub queueStep:[HTTPStubStep status:200 headers:@{@"Content-Type": @"text/html; charset=utf-8",
                                                         @"Set-Cookie": @"t=tok1; Path=/; Domain=dropbox.com; Secure"}
                                     body:html]
             forPath:kFolderPath];
    for (NSData *page in pages) {
        [_stub queueStep:[HTTPStubStep status:200 headers:@{@"Content-Type": @"application/json"} body:page]
                 forPath:kListingPath];
    }
}

- (NSURL *)resolveFolder {
    NSError *error = nil;
    NSURL *playlist = [self resolve:kFolderLink error:&error];
    XCTAssertNotNil(playlist, @"%@", error);
    return playlist;
}

- (NSArray<NSURL *> *)rowsOf:(NSURL *)playlist {
    return [[PlaylistFile rowsForPlaylistAtURL:playlist] valueForKey:@"url"];
}

- (void)testAFolderLinkOpensAsAPlaylistOfItsFilesInListingOrder {
    [self serve:FlacBytes(4000) at:[kFolderPath stringByAppendingString:@"/Track One.flac"] headers:@{@"ETag": @"\"a\""}];
    [self serve:FlacBytes(5000) at:[kFolderPath stringByAppendingString:@"/Live/Encore.flac"] headers:nil];
    [self serve:FlacBytes(6000) at:[kFolderPath stringByAppendingString:@"/Outro.flac"] headers:nil];
    [self queuePageAndListing:@[
        ListingPage(@[ListedFile(@"Track One.flac", 4000, @1700000000), ListedFolder(@"Live"),
                      ListedFile(@"cover.jpg", 900, nil)], @"v2"),
        ListingPage(@[ListedFile(@"Outro.flac", 6000, nil)], nil),
        ListingPage(@[ListedFile(@"Live/Encore.flac", 5000, @1700000100)], nil),
    ]];
    NSTimeInterval before = floor(NSDate.date.timeIntervalSince1970);
    NSURL *playlist = [self resolveFolder];

    XCTAssertEqualObjects(playlist.lastPathComponent, @"Mix Tape.m3u8");
    NSURL *folder = playlist.URLByDeletingLastPathComponent;
    XCTAssertEqualObjects(folder.lastPathComponent,
                          VibeLinkDirectoryName([NSURL URLWithString:@"https://www.dropbox.com/scl/fo/key1/hash1?rlkey=rk"]));
    XCTAssertEqualObjects([self recordOf:playlist][@"url"], @"https://www.dropbox.com/scl/fo/key1/hash1?rlkey=rk");
    NSArray<NSURL *> *rows = [self rowsOf:playlist];
    XCTAssertEqualObjects([rows valueForKey:@"lastPathComponent"], (@[@"Track One.flac", @"Encore.flac", @"Outro.flac"]),
                          @"a folder's files in its place, and no picture");
    for (NSURL *row in rows) {
        XCTAssertTrue(IsPlaceholder(row), @"%@", row);
        XCTAssertEqualObjects(VibeComparablePath(row.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.path),
                              VibeComparablePath(folder.path), @"one directory per file under the folder's");
    }
    XCTAssertEqual(StatOf(rows[0]).st_size, 4000);
    XCTAssertEqual(StatOf(rows[0]).st_mtimespec.tv_sec, 1700000000, @"the listing's ts");
    XCTAssertGreaterThanOrEqual(StatOf(rows[2]).st_mtimespec.tv_sec, before, @"no ts: the open's time");
    NSDictionary *record = [self recordOf:rows[0]];
    XCTAssertEqualObjects(record[@"url"], @"https://www.dropbox.com/scl/fo/key1/hash1/Track%20One.flac?rlkey=rk&dl=1");
    XCTAssertEqualObjects(record[@"ranges"], @YES);
    XCTAssertNil(record[@"version"]);

    NSArray<NSURLRequest *> *listings = [_stub requestsToPath:kListingPath];
    XCTAssertEqual(listings.count, 3u);
    XCTAssertEqualObjects(listings.firstObject.HTTPMethod, @"POST");
    XCTAssertEqualObjects([listings.firstObject valueForHTTPHeaderField:@"Cookie"], @"t=tok1");
    NSString *body = [[NSString alloc] initWithData:VibeFakeHTTPBodyOfRequest(listings[1]) encoding:NSUTF8StringEncoding];
    XCTAssertTrue([body containsString:@"sub_path=&"] && [body containsString:@"voucher=v2"], @"%@", body);
    body = [[NSString alloc] initWithData:VibeFakeHTTPBodyOfRequest(listings[2]) encoding:NSUTF8StringEncoding];
    XCTAssertTrue([body containsString:@"sub_path=Live&"] && [body hasSuffix:@"&t=tok1"], @"%@", body);
    XCTAssertEqual([_stub requestsToPath:[kFolderPath stringByAppendingString:@"/Track One.flac"]].count, 0u,
                   @"no probe of any file");

    [self fetchExpectingSuccess:rows[0]];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:rows[0]], FlacBytes(4000));
    XCTAssertEqual(StatOf(rows[0]).st_mtimespec.tv_sec, 1700000000, @"the download keeps the listed mtime");
}

- (void)testAFolderOpenedAgainKeepsItsDownloads {
    NSString *path = [kFolderPath stringByAppendingString:@"/A.flac"];
    [self serve:FlacBytes(4000) at:path headers:nil];
    NSData *page = ListingPage(@[ListedFile(@"A.flac", 4000, @1700000000)], nil);
    [self queuePageAndListing:@[page]];
    NSURL *playlist = [self resolveFolder];
    NSURL *file = [self rowsOf:playlist].firstObject;
    [self fetchExpectingSuccess:file];
    ino_t inode = StatOf(file).st_ino;
    NSString *key = file.cacheKey;

    [self relaunch];
    [self queuePageAndListing:@[page]];
    XCTAssertEqualObjects([self resolveFolder], playlist);
    XCTAssertEqualObjects([self rowsOf:playlist], @[file]);
    XCTAssertTrue(IsDownloaded(file));
    XCTAssertEqual(StatOf(file).st_ino, inode);
    XCTAssertEqualObjects(file.cacheKey, key);
}

- (void)testAChangedFileIsAPlaceholderAgainAndALeftFileGoes {
    [self serve:FlacBytes(4000) at:[kFolderPath stringByAppendingString:@"/A.flac"] headers:nil];
    [self serve:FlacBytes(5000) at:[kFolderPath stringByAppendingString:@"/B.flac"] headers:nil];
    [self queuePageAndListing:@[ListingPage(@[ListedFile(@"A.flac", 4000, @1700000000),
                                              ListedFile(@"B.flac", 5000, @1700000000)], nil)]];
    NSURL *playlist = [self resolveFolder];
    NSArray<NSURL *> *rows = [self rowsOf:playlist];
    [self fetchExpectingSuccess:rows[0]];
    [self fetchExpectingSuccess:rows[1]];

    [self queuePageAndListing:@[ListingPage(@[ListedFile(@"A.flac", 4000, @1700000500)], nil)]];
    XCTAssertEqualObjects([self resolveFolder], playlist);
    XCTAssertEqualObjects([self rowsOf:playlist], @[rows[0]]);
    XCTAssertTrue(IsPlaceholder(rows[0]), @"another ts is another version");
    XCTAssertEqual(StatOf(rows[0]).st_mtimespec.tv_sec, 1700000500);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:rows[1].URLByDeletingLastPathComponent.path],
                   @"a file that left the folder goes with its download");
}

// A record keyed by the file's own directory, under its folder's: the read
// finds it by the placeholder's URL.
- (void)testATagReadOfAFolderFileChecksItsListedSize {
    [self serve:FlacBytes(4000) at:[kFolderPath stringByAppendingString:@"/A.flac"] headers:nil];
    [self queuePageAndListing:@[ListingPage(@[ListedFile(@"A.flac", 5000, nil)], nil)]];
    NSURL *file = [self rowsOf:[self resolveFolder]].firstObject;
    NSError *error = nil;
    XCTAssertNil([_store readPlaceholderAtURL:file offset:0 length:64 error:&error]);
    XCTAssertEqualObjects(error.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(error.code, VibeHTTPErrorVersionChanged);
}

- (void)testAFolderWithNoAudioIsNotAudio {
    [self queuePageAndListing:@[ListingPage(@[ListedFile(@"cover.jpg", 900, nil), ListedFile(@"notes.txt", 10, nil)],
                                            nil)]];
    XCTAssertEqual([self failureOf:kFolderLink], VibeLinkErrorNotAudio);
    XCTAssertEqualObjects([self linkDirectories], @[], @"nothing written");
}

- (void)testAPageWithNoCookieOrAnAnswerThatIsNoListingIsNotAudio {
    [_stub queueStep:[HTTPStubStep status:200 headers:@{@"Content-Type": @"text/html"} body:[NSData data]]
             forPath:kFolderPath];
    XCTAssertEqual([self failureOf:kFolderLink], VibeLinkErrorNotAudio);
    XCTAssertEqual([_stub requestsToPath:kListingPath].count, 0u);
    [self queuePageAndListing:@[[@"<html>sign in</html>" dataUsingEncoding:NSUTF8StringEncoding]]];
    XCTAssertEqual([self failureOf:kFolderLink], VibeLinkErrorNotAudio);
}

- (void)testADeniedOrMissingFolderFailsAsTheServerSaid {
    [_stub queueStep:[HTTPStubStep status:403 headers:nil body:nil] forPath:kFolderPath];
    XCTAssertEqual([self failureOf:kFolderLink], VibeLinkErrorDenied);
    [_stub queueStep:[HTTPStubStep status:200 headers:@{@"Set-Cookie": @"t=tok1; Path=/"} body:[NSData data]]
             forPath:kFolderPath];
    [_stub queueStep:[HTTPStubStep status:404 headers:nil body:nil] forPath:kListingPath];
    XCTAssertEqual([self failureOf:kFolderLink], VibeLinkErrorNotFound);
}

- (void)testAFolderThatCannotBeReachedOpensItsPlaylist {
    [self serve:FlacBytes(4000) at:[kFolderPath stringByAppendingString:@"/A.flac"] headers:nil];
    [self queuePageAndListing:@[ListingPage(@[ListedFile(@"A.flac", 4000, nil)], nil)]];
    NSURL *playlist = [self resolveFolder];
    NSError *offline = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
    for (NSUInteger i = 0; i < 3; i++) {
        [_stub queueStep:[HTTPStubStep failWithError:offline] forPath:kFolderPath];
    }
    XCTAssertEqualObjects([self resolveFolder], playlist);
    XCTAssertEqual([_stub requestsToPath:kFolderPath].count, 4u, @"sent again twice");
}

- (void)testACancelledFolderOpenWritesNothing {
    [self serve:[@"<html></html>" dataUsingEncoding:NSUTF8StringEncoding] at:kFolderPath
        headers:@{@"Set-Cookie": @"t=tok1; Path=/"}];
    dispatch_semaphore_t gate = [self gate];
    [_stub queueStep:[HTTPStubStep stallAfter:0 gate:gate] forPath:kFolderPath];
    __block NSError *failure = nil;
    dispatch_block_t cancel = [_store resolveURLString:kFolderLink completion:^(NSURL *file, NSError *error) {
        failure = error;
    }];
    [self waitUntil:^BOOL {
        return [self->_stub requestsToPath:kFolderPath].count == 1;
    }];
    cancel();
    XCTAssertEqual(failure.code, VibeLinkErrorCancelled, @"settled before the cancel returns");
    dispatch_semaphore_signal(gate);
    dispatch_sync(_store.diskQueue, ^{
    });
    XCTAssertEqualObjects([self linkDirectories], @[]);
    XCTAssertEqual([_stub requestsToPath:kListingPath].count, 0u, @"no listing after the cancel");
}

- (void)testADropboxShareLinkAsksForTheFile {
    NSMutableData *bytes = [FlacBytes(4000) mutableCopy];
    memcpy(bytes.mutableBytes, "ID3", 3);
    [self serve:bytes at:@"/scl/fi/abc123/Song.mp3" headers:@{@"ETag": @"\"v1\""}];
    NSError *error = nil;
    NSURL *file = [self resolve:@"https://www.dropbox.com/scl/fi/abc123/Song.mp3?rlkey=k1&dl=0" error:&error];
    XCTAssertNotNil(file, @"%@", error);
    XCTAssertEqualObjects(file.lastPathComponent, @"Song.mp3");
    NSURLComponents *sent = [NSURLComponents componentsWithURL:_stub.requests.firstObject.URL resolvingAgainstBaseURL:NO];
    XCTAssertEqualObjects(sent.query, @"rlkey=k1&dl=1");
    XCTAssertEqualObjects([self recordOf:file][@"url"],
                          @"https://www.dropbox.com/scl/fi/abc123/Song.mp3?rlkey=k1&dl=1");
}

@end

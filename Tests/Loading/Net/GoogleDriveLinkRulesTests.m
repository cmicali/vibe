
#import <XCTest/XCTest.h>

#import "GoogleDriveLinkRules.h"
#import "LinkRules.h"
#import "LinkStoreTestCase.h"
#import "PlayableExtensions.h"
#import "PlaylistFile.h"

static NSString *const kDriveFolderPath = @"/drive/v3/files";

static NSDictionary *DriveFile(NSString *fileID, NSString *name, long long size) {
    return @{@"id": fileID, @"name": name, @"mimeType": @"audio/flac", @"size": @(size).stringValue,
             @"modifiedTime": @"2024-05-01T12:34:56.000Z"};
}

static NSDictionary *DriveFolder(NSString *fileID, NSString *name) {
    return @{@"id": fileID, @"name": name, @"mimeType": @"application/vnd.google-apps.folder"};
}

static HTTPStubStep *DriveJSON(NSInteger status, id object) {
    return [HTTPStubStep status:status headers:@{@"Content-Type": @"application/json; charset=UTF-8"}
                           body:[NSJSONSerialization dataWithJSONObject:object options:0 error:NULL]];
}

@interface GoogleDriveLinkRulesTests : XCTestCase
@end

static NSString *Download(NSString *link) {
    return VibeGoogleDriveLinkDownloadURL([NSURL URLWithString:link]).absoluteString;
}

@implementation GoogleDriveLinkRulesTests

- (void)testAGoogleDriveFileLinkGetsItsDownloadAddress {
    NSString *download = @"https://drive.usercontent.google.com/download?id=1k_kSNfbzdX-Ab&export=download&confirm=t";
    for (NSString *link in @[@"https://drive.google.com/file/d/1k_kSNfbzdX-Ab/view?usp=sharing",
                             @"https://drive.google.com/file/d/1k_kSNfbzdX-Ab/view",
                             @"https://drive.google.com/file/d/1k_kSNfbzdX-Ab/edit?usp=drive_link",
                             @"https://drive.google.com/file/d/1k_kSNfbzdX-Ab/preview",
                             @"https://drive.google.com/file/d/1k_kSNfbzdX-Ab",
                             @"https://drive.google.com/file/d/1k_kSNfbzdX-Ab/",
                             @"https://DRIVE.GOOGLE.COM/file/d/1k_kSNfbzdX-Ab/view#frag",
                             @"https://drive.google.com/open?id=1k_kSNfbzdX-Ab",
                             @"https://drive.google.com/open?usp=sharing&id=1k_kSNfbzdX-Ab",
                             @"https://drive.google.com/uc?id=1k_kSNfbzdX-Ab&export=download",
                             @"https://drive.google.com/uc?export=download&id=1k_kSNfbzdX-Ab",
                             @"https://drive.google.com/uc?id=1k_kSNfbzdX-Ab"]) {
        XCTAssertEqualObjects(Download(link), download, @"%@", link);
    }
}

- (void)testAGoogleDriveResourceKeyIsKept {
    NSString *download =
        @"https://drive.usercontent.google.com/download?id=1AbC&export=download&confirm=t&resourcekey=0-xYz_9";
    for (NSString *link in @[@"https://drive.google.com/file/d/1AbC/view?usp=sharing&resourcekey=0-xYz_9",
                             @"https://drive.google.com/file/d/1AbC/view?resourcekey=0-xYz_9",
                             @"https://drive.google.com/open?id=1AbC&resourcekey=0-xYz_9",
                             @"https://drive.google.com/uc?id=1AbC&export=download&resourcekey=0-xYz_9"]) {
        XCTAssertEqualObjects(Download(link), download, @"%@", link);
    }
    XCTAssertEqualObjects(Download(@"https://drive.google.com/file/d/1AbC/view?resourcekey="),
                          @"https://drive.usercontent.google.com/download?id=1AbC&export=download&confirm=t");
}

- (void)testAnythingButAFileLinkIsNotOne {
    for (NSString *string in @[@"https://drive.google.com/drive/folders/1AbC_d-E?usp=sharing",
                               @"https://drive.google.com/drive/u/0/folders/1AbC_d-E",
                               @"https://drive.google.com/",
                               @"https://drive.google.com/file/d/",
                               @"https://drive.google.com/file/x/1AbC_d-E/view",
                               @"https://drive.google.com/open",
                               @"https://drive.google.com/open?id=",
                               @"https://drive.google.com/uc?export=download",
                               @"https://drive.google.com/file/d/1AbC%2F..%2Fx/view",
                               @"https://drive.google.com/open?id=1AbC%26x%3D1",
                               @"https://drive.google.com/drive/open?id=1AbC_d-E",
                               @"https://docs.google.com/file/d/1AbC_d-E/view",
                               @"https://drive.google.com.evil.example/file/d/1AbC_d-E/view",
                               @"https://drive.usercontent.google.com/download?id=1AbC_d-E&export=download"]) {
        XCTAssertNil(VibeGoogleDriveLinkDownloadURL([NSURL URLWithString:string]), @"%@", string);
    }
}

- (void)testAFolderLinkNamesItsFolder {
    for (NSString *link in @[@"https://drive.google.com/drive/folders/1wzjcx1GcmYpXHiLAjfL6L3CB4nd-v2ji",
                             @"https://drive.google.com/drive/folders/1wzjcx1GcmYpXHiLAjfL6L3CB4nd-v2ji?usp=sharing",
                             @"https://drive.google.com/drive/folders/1wzjcx1GcmYpXHiLAjfL6L3CB4nd-v2ji/",
                             @"https://DRIVE.google.com/drive/u/0/folders/1wzjcx1GcmYpXHiLAjfL6L3CB4nd-v2ji",
                             @"https://drive.google.com/drive/u/12/folders/1wzjcx1GcmYpXHiLAjfL6L3CB4nd-v2ji",
                             @"https://drive.google.com/drive/mobile/folders/1wzjcx1GcmYpXHiLAjfL6L3CB4nd-v2ji"]) {
        XCTAssertEqualObjects(VibeGoogleDriveFolderLink([NSURL URLWithString:link]),
                              @{@"id": @"1wzjcx1GcmYpXHiLAjfL6L3CB4nd-v2ji"}, @"%@", link);
    }
    NSDictionary *keyed = VibeGoogleDriveFolderLink(
            [NSURL URLWithString:@"https://drive.google.com/drive/folders/1AbC?usp=sharing&resourcekey=0-xYz_9"]);
    XCTAssertEqualObjects(keyed, (@{@"id": @"1AbC", @"resourceKey": @"0-xYz_9"}));
    XCTAssertEqualObjects(VibeGoogleDriveFolderLinkURL(keyed).absoluteString,
                          @"https://drive.google.com/drive/folders/1AbC?resourcekey=0-xYz_9");
    XCTAssertEqualObjects(VibeGoogleDriveFolderLinkURL(@{@"id": @"1AbC"}).absoluteString,
                          @"https://drive.google.com/drive/folders/1AbC");
    XCTAssertEqualObjects(VibeGoogleDriveResourceKeysHeader(keyed), @"1AbC/0-xYz_9");
    XCTAssertNil(VibeGoogleDriveResourceKeysHeader(@{@"id": @"1AbC"}));
}

- (void)testAnythingButAFolderLinkNamesNoFolder {
    for (NSString *string in @[@"https://drive.google.com/file/d/1AbC/view",
                               @"http://drive.google.com/drive/folders/1AbC",
                               @"https://drive.google.com/drive/folders/",
                               @"https://drive.google.com/drive/folders/1AbC%2Fx",
                               @"https://drive.google.com/drive/x/folders/1AbC",
                               @"https://drive.google.com/drive/u/me/folders/1AbC",
                               @"https://drive.google.com/folders/1AbC",
                               @"https://docs.google.com/drive/folders/1AbC",
                               @"https://drive.google.com.evil.example/drive/folders/1AbC"]) {
        XCTAssertNil(VibeGoogleDriveFolderLink([NSURL URLWithString:string]), @"%@", string);
    }
}

- (void)testTheAPIRequestsAskForOneFolderWithTheKey {
    NSURLComponents *list = [NSURLComponents componentsWithURL:VibeGoogleDriveFolderListURL(@"1AbC", @"k1", nil)
                                       resolvingAgainstBaseURL:NO];
    XCTAssertEqualObjects(list.host, @"www.googleapis.com");
    XCTAssertEqualObjects(list.path, @"/drive/v3/files");
    NSMutableDictionary<NSString *, NSString *> *items = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in list.queryItems) {
        items[item.name] = item.value;
    }
    XCTAssertEqualObjects(items[@"q"], @"'1AbC' in parents and trashed = false");
    XCTAssertEqualObjects(items[@"key"], @"k1");
    XCTAssertEqualObjects(items[@"pageSize"], @"1000");
    XCTAssertNil(items[@"pageToken"]);
    XCTAssertTrue([items[@"fields"] containsString:@"nextPageToken"]);
    NSURLComponents *next = [NSURLComponents componentsWithURL:VibeGoogleDriveFolderListURL(@"1AbC", @"k1", @"p2")
                                       resolvingAgainstBaseURL:NO];
    XCTAssertEqualObjects(next.queryItems.lastObject, [NSURLQueryItem queryItemWithName:@"pageToken" value:@"p2"]);
    NSURLComponents *metadata = [NSURLComponents componentsWithURL:VibeGoogleDriveFolderMetadataURL(@"1AbC", @"k1")
                                           resolvingAgainstBaseURL:NO];
    XCTAssertEqualObjects(metadata.path, @"/drive/v3/files/1AbC");
    XCTAssertTrue([metadata.query containsString:@"key=k1"]);
}

- (void)testAListingPageReadsFilesAndFolders {
    id answer = @{
        @"nextPageToken": @"p2",
        @"files": @[
            @{@"id": @"1Fold", @"name": @"Live", @"mimeType": @"application/vnd.google-apps.folder", @"resourceKey": @"0-r"},
            @{@"id": @"1Song", @"name": @"Song.flac", @"mimeType": @"audio/flac", @"size": @"4000",
              @"modifiedTime": @"2024-05-01T12:34:56.789Z"},
            @{@"id": @"1Same", @"name": @"Song.flac", @"mimeType": @"audio/flac", @"size": @"10",
              @"modifiedTime": @"2024-05-01T12:34:56Z", @"resourceKey": @"0-s"},
            @{@"id": @"1Doc", @"name": @"Notes", @"mimeType": @"application/vnd.google-apps.document"},
            @{@"id": @"1Cut", @"name": @"Link.mp3", @"mimeType": @"application/vnd.google-apps.shortcut"},
            @{@"id": @"1NoSize", @"name": @"x.mp3", @"mimeType": @"audio/mpeg"},
            @{@"id": @"bad/id", @"name": @"y.mp3", @"mimeType": @"audio/mpeg", @"size": @"1"},
            @"not a file",
        ],
    };
    NSString *next = nil;
    NSArray<NSDictionary *> *entries = VibeGoogleDriveFolderListingEntries(answer, &next);
    XCTAssertEqual(entries.count, 3u, @"%@", entries);
    XCTAssertEqualObjects(entries[0], (@{@"name": @"Live", @"folder": @{@"id": @"1Fold", @"resourceKey": @"0-r"}}));
    XCTAssertEqualObjects(entries[1][@"size"], @4000);
    XCTAssertEqualObjects(entries[1][@"modified"], @1714566896);
    XCTAssertEqualObjects([entries[1][@"url"] absoluteString],
                          @"https://drive.usercontent.google.com/download?id=1Song&export=download&confirm=t");
    XCTAssertEqualObjects([entries[2][@"url"] absoluteString],
                          @"https://drive.usercontent.google.com/download?id=1Same&export=download&confirm=t&resourcekey=0-s",
                          @"a repeated name is another file");
    XCTAssertEqualObjects(next, @"p2");
    VibeGoogleDriveFolderListingEntries(@{@"files": @[]}, &next);
    XCTAssertNil(next);
    XCTAssertNil(VibeGoogleDriveFolderListingEntries(@{@"error": @{@"code": @404}}, NULL));
}

- (void)testTheShareLinkRewriteAsksThisFile {
    NSURL *download = VibeLinkDirectDownloadURL([NSURL URLWithString:@"https://drive.google.com/file/d/1AbC/view"]);
    XCTAssertEqualObjects(download.absoluteString,
                          @"https://drive.usercontent.google.com/download?id=1AbC&export=download&confirm=t");
    XCTAssertEqual(VibeLinkURLAcceptance(download), VibeLinkErrorNone);
    XCTAssertEqualObjects(VibeLinkFileName(download, nil, @"wav", PlayableExtensions.lookup), @"download.wav");
    NSURL *folder = [NSURL URLWithString:@"https://drive.google.com/drive/folders/1AbC_d-E"];
    XCTAssertEqualObjects(VibeLinkDirectDownloadURL(folder), folder, @"fetched as typed");
}

@end

// A Google Drive link through the real LinkStore, over HTTPStub answering
// Google's download host.
@interface GoogleDriveLinkStoreTests : LinkStoreTestCase
@end

@implementation GoogleDriveLinkStoreTests

// The headers Google answered for a shared WAV: no ETag, and the name only in
// Content-Disposition.
- (void)testAGoogleDriveLinkAsksForTheFileAndTakesItsName {
    [_stub answerHost:@"drive.usercontent.google.com"];
    NSMutableData *bytes = [FlacBytes(4000) mutableCopy];
    memcpy(bytes.mutableBytes, "RIFF\x01\x02\x03\x04WAVE", 12);
    [self serve:bytes at:@"/download" headers:@{
        @"Content-Type": @"audio/wav",
        @"Content-Disposition": @"attachment; filename=\"07A - Greg Benz Remix 0710.wav\"",
        @"Last-Modified": kModified,
    }];
    NSError *error = nil;
    NSURL *file = [self resolve:@"https://drive.google.com/file/d/1k_kSNfbzdX-Ab/view?usp=sharing" error:&error];
    XCTAssertNotNil(file, @"%@", error);
    XCTAssertEqualObjects(file.lastPathComponent, @"07A - Greg Benz Remix 0710.wav");
    NSURLComponents *sent = [NSURLComponents componentsWithURL:_stub.requests.firstObject.URL resolvingAgainstBaseURL:NO];
    XCTAssertEqualObjects(sent.query, @"id=1k_kSNfbzdX-Ab&export=download&confirm=t");
    NSDictionary *record = [self recordOf:file];
    XCTAssertEqualObjects(record[@"url"],
                          @"https://drive.usercontent.google.com/download?id=1k_kSNfbzdX-Ab&export=download&confirm=t");
    XCTAssertEqualObjects(record[@"version"], kModified, @"no ETag: the version is Last-Modified");
    XCTAssertEqualObjects(record[@"ranges"], @YES);
    XCTAssertEqual(StatOf(file).st_size, 4000);
}

#pragma mark Folders

- (void)setUpDrive {
    [_stub answerHost:@"www.googleapis.com"];
    [_stub answerHost:@"drive.usercontent.google.com"];
    _client.googleDriveAPIKey = @"k1";
}

// files.get naming the folder, then files.list's pages in the order the
// folder's requests reach them.
- (void)queueDriveFolder:(NSString *)folderID name:(NSString *)name pages:(NSArray<NSDictionary *> *)pages {
    [_stub queueStep:DriveJSON(200, @{@"id": folderID, @"name": name,
                                      @"mimeType": @"application/vnd.google-apps.folder"})
             forPath:[NSString stringWithFormat:@"%@/%@", kDriveFolderPath, folderID]];
    for (NSDictionary *page in pages) {
        [_stub queueStep:DriveJSON(200, page) forPath:kDriveFolderPath];
    }
}

- (void)testADriveFolderLinkOpensAsAPlaylistThroughTheAPI {
    [self setUpDrive];
    [self serve:FlacBytes(4000) at:@"/download" headers:@{@"Last-Modified": kModified}];
    [self queueDriveFolder:@"1Root" name:@"Mix Tape" pages:@[
        @{@"files": @[DriveFolder(@"1Live", @"Live"), DriveFile(@"1A", @"A.flac", 4000)], @"nextPageToken": @"p2"},
        @{@"files": @[DriveFile(@"1B", @"B.flac", 4000),
                      @{@"id": @"1Doc", @"name": @"Notes", @"mimeType": @"application/vnd.google-apps.document"}]},
        @{@"files": @[DriveFile(@"1C", @"C.flac", 4000)]},
    ]];
    NSError *error = nil;
    NSURL *playlist = [self resolve:@"https://drive.google.com/drive/folders/1Root?usp=sharing" error:&error];
    XCTAssertNotNil(playlist, @"%@", error);
    XCTAssertEqualObjects(playlist.lastPathComponent, @"Mix Tape.m3u8");
    XCTAssertEqualObjects([self recordOf:playlist][@"url"], @"https://drive.google.com/drive/folders/1Root");

    NSArray<NSURL *> *rows = [[PlaylistFile rowsForPlaylistAtURL:playlist] valueForKey:@"url"];
    XCTAssertEqualObjects([rows valueForKey:@"lastPathComponent"], (@[@"C.flac", @"A.flac", @"B.flac"]),
                          @"a folder's files in its place, and no Google Doc");
    XCTAssertTrue(IsPlaceholder(rows[1]));
    XCTAssertEqual(StatOf(rows[1]).st_size, 4000);
    XCTAssertEqual(StatOf(rows[1]).st_mtimespec.tv_sec, 1714566896, @"the listed modifiedTime");
    XCTAssertEqualObjects([self recordOf:rows[1]][@"url"],
                          @"https://drive.usercontent.google.com/download?id=1A&export=download&confirm=t");

    NSArray<NSURLRequest *> *lists = [_stub requestsToPath:kDriveFolderPath];
    XCTAssertEqual(lists.count, 3u);
    NSURLComponents *first = [NSURLComponents componentsWithURL:lists.firstObject.URL resolvingAgainstBaseURL:NO];
    XCTAssertTrue([first.percentEncodedQuery containsString:@"key=k1"]);
    XCTAssertTrue([[NSURLComponents componentsWithURL:lists[1].URL resolvingAgainstBaseURL:NO].query
                   containsString:@"pageToken=p2"]);
    XCTAssertTrue([[NSURLComponents componentsWithURL:lists[2].URL resolvingAgainstBaseURL:NO].query
                   containsString:@"'1Live' in parents"]);
    XCTAssertEqual([_stub requestsToPath:@"/download"].count, 0u, @"no probe of any file");

    [self fetchExpectingSuccess:rows[1]];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:rows[1]], FlacBytes(4000));
    XCTAssertEqual(StatOf(rows[1]).st_mtimespec.tv_sec, 1714566896, @"the download keeps the listed mtime");
}

- (void)testADriveFoldersResourceKeyRidesEveryRequestAboutIt {
    [self setUpDrive];
    [self queueDriveFolder:@"1Root" name:@"Mix" pages:@[@{@"files": @[DriveFile(@"1A", @"A.flac", 4000)]}]];
    NSError *error = nil;
    XCTAssertNotNil([self resolve:@"https://drive.google.com/drive/folders/1Root?resourcekey=0-k" error:&error], @"%@",
                    error);
    NSURLRequest *metadata = [_stub requestsToPath:[kDriveFolderPath stringByAppendingString:@"/1Root"]].firstObject;
    XCTAssertEqualObjects([metadata valueForHTTPHeaderField:@"X-Goog-Drive-Resource-Keys"], @"1Root/0-k");
    NSURLRequest *list = [_stub requestsToPath:kDriveFolderPath].firstObject;
    XCTAssertEqualObjects([list valueForHTTPHeaderField:@"X-Goog-Drive-Resource-Keys"], @"1Root/0-k");
}

- (void)testADriveFolderWithNoKeyOrThatIsAFileIsNotAudio {
    [self setUpDrive];
    _client.googleDriveAPIKey = nil;
    XCTAssertEqual([self failureOf:@"https://drive.google.com/drive/folders/1Root"], VibeLinkErrorNotAudio);
    XCTAssertEqual(_stub.requests.count, 0u, @"nothing asked without a key");
    _client.googleDriveAPIKey = @"k1";
    [_stub queueStep:DriveJSON(200, @{@"id": @"1Root", @"name": @"x.flac", @"mimeType": @"audio/flac"})
             forPath:[kDriveFolderPath stringByAppendingString:@"/1Root"]];
    XCTAssertEqual([self failureOf:@"https://drive.google.com/drive/folders/1Root"], VibeLinkErrorNotAudio);
    XCTAssertEqual([_stub requestsToPath:kDriveFolderPath].count, 0u);
    XCTAssertEqualObjects([self linkDirectories], @[]);
}

- (void)testADriveFolderTheAPICannotSeeIsNotFound {
    [self setUpDrive];
    [_stub queueStep:DriveJSON(404, @{@"error": @{@"code": @404, @"message": @"File not found: 1Root."}})
             forPath:[kDriveFolderPath stringByAppendingString:@"/1Root"]];
    XCTAssertEqual([self failureOf:@"https://drive.google.com/drive/folders/1Root"], VibeLinkErrorNotFound);
}

// A private or over-quota file answers a sign-in or quota page instead.
- (void)testAGooglePageInsteadOfTheFileFailsClearly {
    [_stub answerHost:@"drive.usercontent.google.com"];
    NSString *link = @"https://drive.google.com/file/d/1abc/view?usp=sharing";
    NSData *page = [@"<!DOCTYPE html><html><head><title>Sign in</title></head></html>"
                    dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *html = @{@"Content-Type": @"text/html; charset=utf-8"};
    HTTPStubFile *served = [self serve:page at:@"/download" headers:html];

    [_stub queueStep:[HTTPStubStep status:403 headers:html body:page] forPath:@"/download"];
    XCTAssertEqual([self failureOf:link], VibeLinkErrorDenied);

    XCTAssertEqual([self failureOf:link], VibeLinkErrorNotAudio, @"a page with its length");

    served.ignoresRanges = YES;
    served.omitsLength = YES;
    XCTAssertEqual([self failureOf:link], VibeLinkErrorNotAudio, @"a page with no length");
    XCTAssertEqualObjects([self linkDirectories], @[]);
}

@end

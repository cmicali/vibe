//
//  DropboxMirrorTestCase.h
//
//  The harness the Dropbox tests share: the real client and mirror over
//  DropboxStubProtocol and a per-test temp root, the stub's default
//  answers, and the helpers more than one topic uses. It runs no tests.
//  DropboxMirrorTests, DropboxMirrorFetchTests and DropboxMirrorStreamingTests
//  subclass it.
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/time.h>

#import "AudioFileHandle.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioFileOpenRules.h"
#import "AudioFixtures.h"
#import "CloudFileMaterializer.h"
#import "CloudTransferRegistry.h"
#import "DropboxClientInternal.h"
#import "DropboxMirror.h"
#import "DropboxRules.h"
#import "DropboxStubProtocol.h"
#import "HTTPStub.h"
#import "PlaceholderFiles.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *const kStamp = @"2020-01-02T03:04:05Z";
static const time_t kStampSeconds = 1577934245;
static NSString *const kRev = @"015c0ffee";

// files/download as Dropbox answers it: the whole file, or 206 from a Range's
// first byte, with the version's metadata either way; 416 for a range that
// starts at or past the file's end.
DropboxStubResponse DownloadAnswer(NSURLRequest *request, NSData *bytes, NSDictionary *metadata);

// The answer to `request` cut off after `delivered` bytes by a dropped
// connection, once `part` holds them.
DropboxStubResponse Dropped(DropboxStubResponse answer, NSURLRequest *request, NSUInteger delivered, NSURL *part);

NSDictionary *FileEntry(NSString *folder, NSString *name, long long size, NSString *modified);
NSDictionary *FolderEntry(NSString *folder, NSString *name);
// A range with an end: a tail or a tag read, never a download.
BOOL IsClosedRange(NSURLRequest *request);

@interface DropboxMirrorTestCase : XCTestCase {
@protected
    NSURL *_root;
    DropboxClient *_client;
    DropboxMirror *_mirror;
    // Path → entries the stub's list_folder answers.
    NSMutableDictionary<NSString *, NSArray *> *_listings;
    // Dropbox path → bytes the stub's files/download answers.
    NSMutableDictionary<NSString *, NSData *> *_contents;
    // Under scriptDownloads:, what answers a closed range (a tail or a tag
    // read beside the downloads); nil answers it as default.
    DropboxStubResponse (^_rangeScript)(NSURLRequest *request);
    NSInteger _tokenRequests;
    // What the stub's files/search_v2 answers.
    NSArray<NSDictionary *> *_searchEntries;
}
- (void)spinMainQueue;
// Until `count` requests have reached `path`, or the hang guard runs out;
// the caller asserts the count it needs.
- (void)waitForRequests:(NSUInteger)count toPath:(NSString *)path;
- (void)installHandler:(nullable DropboxStubHandler)handler;
- (void)clearRequests;
- (NSArray<NSURLRequest *> *)requestsToPath:(NSString *)path;
- (DropboxStubResponse)defaultResponseFor:(NSURLRequest *)request json:(nullable NSDictionary *)json;
- (NSURL *)refresh:(NSString *)path;
- (void)installMirrorFetch;
- (long long)measuredDownloads;
// Inside the account's directory: the adopt's account change prunes
// everything else under the root, and lands whenever the main queue turns.
- (NSURL *)partURL;
// Files/download's answers by request, counted from 0; the rest as default,
// closed ranges through _rangeScript.
- (void)scriptDownloads:(DropboxStubResponse (^)(NSInteger index, NSURLRequest *request))script;
- (DropboxStubResponse)answer:(NSURLRequest *)request;
// Spins main, which carries the registry's edges and fractions.
- (BOOL)eventually:(BOOL (^)(void))condition;
@end

NS_ASSUME_NONNULL_END

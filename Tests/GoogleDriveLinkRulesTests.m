//
//  GoogleDriveLinkRulesTests.m
//
//  Open URL's Google Drive share links: which links become Google's download
//  address, and that the share-link rewrite asks this file.
//

#import <XCTest/XCTest.h>

#import "GoogleDriveLinkRules.h"
#import "LinkRules.h"
#import "PlayableExtensions.h"

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

// The rewrite asks this file, and the address it makes is a link Vibe
// fetches like any other.
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

//
//  LinkDropRulesTests.m
//
//  What a drop or a paste opens: which items are web links, how a .webloc is
//  read, and the order a drop opens in.
//

#import <XCTest/XCTest.h>

#import "LinkDropRules.h"

@interface LinkDropRulesTests : XCTestCase
@end

static NSData *Text(NSString *text) {
    return [text dataUsingEncoding:NSASCIIStringEncoding];
}

static NSURL *U(NSString *string) {
    return [NSURL URLWithString:string];
}

static NSDictionary<NSString *, NSString *> *FileItem(NSString *url) {
    return @{kVibeDropTypeFileURL: url, kVibeDropTypeText: url.lastPathComponent};
}

static NSData *Webloc(id plist, NSPropertyListFormat format) {
    return [NSPropertyListSerialization dataWithPropertyList:plist format:format options:0 error:NULL];
}

@implementation LinkDropRulesTests

// Safari and Chrome write the link as a URL, and as text beside it. Firefox
// may write only the text.
- (void)testABrowserLinkDragIsALink {
    NSString *link = @"https://example.com/music/a.mp3";
    NSArray *safari = @[@{kVibeDropTypeURL: link, @"public.url-name": @"a.mp3", kVibeDropTypeText: link}];
    XCTAssertEqualObjects(VibeDropURLsOfItems(safari), @[U(link)]);
    XCTAssertEqualObjects(VibeDropURLsOfItems(@[@{kVibeDropTypeText: link}]), @[U(link)]);
    XCTAssertEqualObjects(VibeDropURLsOfItems(@[@{kVibeDropTypeURL: @"http://nas.local/a.flac"}]),
                          @[U(@"http://nas.local/a.flac")]);
}

// A pasted link often carries spaces and a newline.
- (void)testTextAroundOneLinkIsTrimmed {
    NSArray *items = @[@{kVibeDropTypeText: @"  \n https://example.com/a.mp3\t\n"}];
    XCTAssertEqualObjects(VibeDropURLsOfItems(items), @[U(@"https://example.com/a.mp3")]);
}

// Text that is not one web link adds nothing, so the drag is refused.
- (void)testTextThatIsNoLinkAddsNothing {
    for (NSString *text in @[@"", @"  ", @"hello world", @"example.com/a.mp3", @"/Users/me/a.mp3",
                             @"Listen: https://example.com/a.mp3", @"https://"]) {
        XCTAssertEqualObjects(VibeDropURLsOfItems(@[@{kVibeDropTypeText: text}]), @[], @"%@", text);
    }
    XCTAssertEqualObjects(VibeDropURLsOfItems(@[@{}]), @[]);
    XCTAssertEqualObjects(VibeDropURLsOfItems(@[]), @[]);
}

// Only http and https are links. Another scheme is refused at the drag.
- (void)testOnlyHTTPAndHTTPSAreLinks {
    for (NSString *link in @[@"ftp://example.com/a.mp3", @"javascript:alert(1)", @"mailto:a@example.com",
                             @"data:audio/mpeg;base64,AAAA", @"file:///Users/me/a.mp3", @"vibe://open"]) {
        XCTAssertEqualObjects(VibeDropURLsOfItems(@[@{kVibeDropTypeURL: link}]), @[], @"%@", link);
        XCTAssertEqualObjects(VibeDropURLsOfItems(@[@{kVibeDropTypeText: link}]), @[], @"%@", link);
        XCTAssertFalse(VibeLinkIsWebLink(U(link)), @"%@", link);
    }
    // Plain http to a public host is a link. Its resolve refuses it before
    // any request, as the prompt's does.
    NSURL *insecure = U(@"http://example.com/a.mp3");
    XCTAssertEqualObjects(VibeDropURLsOfItems(@[@{kVibeDropTypeURL: insecure.absoluteString}]), @[insecure]);
    XCTAssertEqual(VibeLinkURLAcceptance(insecure), VibeLinkErrorInsecure);
}

// Finder's file wins over its text. A file reference URL is kept as it came,
// since the shell pins its path.
- (void)testAFileIsAFile {
    NSString *reference = @"file:///.file/id=6571367.2773272/";
    NSArray *items = @[FileItem(@"file:///Users/me/Music/a.flac"), FileItem(reference)];
    XCTAssertEqualObjects(VibeDropURLsOfItems(items), (@[U(@"file:///Users/me/Music/a.flac"), U(reference)]));
    // A file URL item that is not one adds nothing, whatever its text says.
    XCTAssertEqualObjects(VibeDropURLsOfItems(@[@{kVibeDropTypeFileURL: @"https://example.com/a.mp3",
                                                  kVibeDropTypeText: @"https://example.com/a.mp3"}]), @[]);
    XCTAssertFalse(VibeDropHasLinks(@[U(@"file:///Users/me/Music/a.flac"), U(@"file:///Users/me/Music")]));
    XCTAssertFalse(VibeDropHasLinks(@[]));
}

// A paste opens its first web link. Files and text that is not one link are
// skipped. Nothing found is the invalid-link error.
- (void)testAPasteOpensItsFirstWebLink {
    NSArray *items = @[@{kVibeDropTypeText: @"hello world"},
                       FileItem(@"file:///Users/me/Music/a.flac"),
                       @{kVibeDropTypeURL: @"https://example.com/b.mp3", kVibeDropTypeText: @"Song B"},
                       @{kVibeDropTypeText: @"https://example.com/c.mp3"}];
    XCTAssertEqualObjects(VibePasteLinkOfItems(items), U(@"https://example.com/b.mp3"));
    XCTAssertEqualObjects(VibePasteLinkOfItems(@[@{kVibeDropTypeText: @" https://example.com/a.mp3\n"}]),
                          U(@"https://example.com/a.mp3"));
    // Plain http is a link. Its resolve refuses a public host as insecure.
    XCTAssertEqualObjects(VibePasteLinkOfItems(@[@{kVibeDropTypeText: @"http://example.com/a.mp3"}]),
                          U(@"http://example.com/a.mp3"));
    for (NSString *text in @[@"", @"example.com/a.mp3", @"Listen: https://example.com/a.mp3",
                             @"ftp://example.com/a.mp3", @"file:///Users/me/a.mp3"]) {
        XCTAssertNil(VibePasteLinkOfItems(@[@{kVibeDropTypeText: text}]), @"%@", text);
    }
    XCTAssertNil(VibePasteLinkOfItems(@[FileItem(@"file:///Users/me/Music/a.flac")]));
    XCTAssertNil(VibePasteLinkOfItems(@[]));
}

- (void)testAWeblocIsALink {
    NSURL *webloc = [NSURL fileURLWithPath:@"/Users/me/Desktop/Song.WEBLOC"];
    XCTAssertTrue(VibeLinkIsWebloc(webloc));
    XCTAssertTrue(VibeDropHasLinks(@[U(@"file:///Users/me/a.flac"), webloc]));
    XCTAssertTrue(VibeDropHasLinks(@[U(@"https://example.com/a.mp3")]));
    XCTAssertFalse(VibeLinkIsWebloc(U(@"https://example.com/a.webloc")));
    XCTAssertFalse(VibeLinkIsWebloc([NSURL fileURLWithPath:@"/Users/me/webloc"]));
}

// Finder writes a binary plist. Older ones, and other apps, write XML.
- (void)testAWeblocReadsInBothForms {
    NSDictionary *plist = @{@"URL": @"https://example.com/a.mp3"};
    for (NSNumber *format in @[@(NSPropertyListBinaryFormat_v1_0), @(NSPropertyListXMLFormat_v1_0)]) {
        NSData *data = Webloc(plist, format.unsignedIntegerValue);
        XCTAssertEqualObjects(VibeLinkURLOfWebloc(data), U(@"https://example.com/a.mp3"));
    }
    NSData *spaced = Webloc(@{@"URL": @" https://example.com/b.mp3\n"}, NSPropertyListXMLFormat_v1_0);
    XCTAssertEqualObjects(VibeLinkURLOfWebloc(spaced), U(@"https://example.com/b.mp3"));
}

- (void)testAWeblocWithNoWebLinkOpensNothing {
    NSPropertyListFormat xml = NSPropertyListXMLFormat_v1_0;
    XCTAssertNil(VibeLinkURLOfWebloc(Webloc(@{@"url": @"https://example.com/a.mp3"}, xml)));
    XCTAssertNil(VibeLinkURLOfWebloc(Webloc(@{}, xml)));
    XCTAssertNil(VibeLinkURLOfWebloc(Webloc(@{@"URL": @42}, xml)));
    XCTAssertNil(VibeLinkURLOfWebloc(Webloc(@[@"https://example.com/a.mp3"], xml)));
    XCTAssertNil(VibeLinkURLOfWebloc(Webloc(@{@"URL": @"ftp://example.com/a.mp3"}, xml)));
    XCTAssertNil(VibeLinkURLOfWebloc(Webloc(@{@"URL": @"javascript:alert(1)"}, xml)));
    XCTAssertNil(VibeLinkURLOfWebloc(Text(@"not a property list")));
    XCTAssertNil(VibeLinkURLOfWebloc([NSData data]));
    XCTAssertNil(VibeLinkURLOfWebloc(nil));
}

// One drop, several links: each once, in drop order.
- (void)testSeveralLinksOpenInDropOrderOnce {
    NSArray *items = @[@{kVibeDropTypeURL: @"https://b.example.com/2.mp3"},
                       @{kVibeDropTypeText: @"https://a.example.com/1.mp3"},
                       @{kVibeDropTypeURL: @"https://b.example.com/2.mp3"},
                       @{kVibeDropTypeURL: @"HTTPS://B.EXAMPLE.COM/2.mp3#t=10"},
                       @{kVibeDropTypeURL: @"https://b.example.com/3.mp3"}];
    NSArray<NSURL *> *dropped = VibeDropURLsOfItems(items);
    XCTAssertEqual(dropped.count, 5u);
    NSArray<NSURL *> *order = VibeDropOpenOrder(dropped, ^NSData *(NSURL *url) {
        XCTFail(@"read %@", url);
        return nil;
    });
    XCTAssertEqualObjects(order, (@[U(@"https://b.example.com/2.mp3"), U(@"https://a.example.com/1.mp3"),
                                    U(@"https://b.example.com/3.mp3")]));
}

// Files and links open together, in the order they were dropped. A .webloc
// stands where it was dropped. One that cannot be read drops out, as does
// a link it repeats.
- (void)testFilesAndLinksOpenInDropOrder {
    NSURL *first = [NSURL fileURLWithPath:@"/Users/me/Music/1.flac"];
    NSURL *folder = [NSURL fileURLWithPath:@"/Users/me/Music/Album" isDirectory:YES];
    NSURL *webloc = [NSURL fileURLWithPath:@"/Users/me/Desktop/2.webloc"];
    NSURL *again = [NSURL fileURLWithPath:@"/Users/me/Desktop/again.webloc"];
    NSURL *unreadable = [NSURL fileURLWithPath:@"/Users/me/Desktop/gone.webloc"];
    NSURL *link = U(@"https://example.com/3.mp3");
    NSMutableArray<NSURL *> *read = [NSMutableArray array];
    NSArray<NSURL *> *order = VibeDropOpenOrder(@[first, webloc, link, folder, again, unreadable, first],
                                                ^NSData *(NSURL *url) {
        [read addObject:url];
        if ([url isEqual:unreadable]) return nil;
        NSString *target = [url isEqual:webloc] ? @"https://example.com/2.mp3" : @"https://example.com/3.mp3";
        return Webloc(@{@"URL": target}, NSPropertyListBinaryFormat_v1_0);
    });
    XCTAssertEqualObjects(order, (@[first, U(@"https://example.com/2.mp3"), link, folder, first]));
    XCTAssertEqualObjects(read, (@[webloc, again, unreadable]));
}

@end

#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#import "FilePaths.h"

@interface FilePathsTests : XCTestCase
@end

@implementation FilePathsTests

- (void)testEquivalentFilePathsShareOneClaimSpelling {
    NSURL *direct = [NSURL fileURLWithPath:@"/tmp/vibe/audio.flac"];
    NSURL *lexicalAlias = [NSURL fileURLWithPath:@"/tmp/vibe/part/../audio.flac"];
    XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(direct),
                          VibeStandardizedAudioOpenPath(lexicalAlias));
}

- (void)testNonFileURLUsesItsAbsoluteIdentity {
    NSURL *url = [NSURL URLWithString:@"https://example.com/audio.flac?take=2"];
    XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(url), url.absoluteString);
}

- (void)testFileIdentityNormalizesAliasesWithoutProbingTheFilesystem {
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSString *path = [@"/var/vibe-open-" stringByAppendingString:identifier];
    NSArray<NSString *> *aliases = @[
        path,
        [@"/private" stringByAppendingString:path],
        [@"/System/Volumes/Data/private" stringByAppendingString:path],
        [path stringByAppendingString:@"/folder/.."],
        [path stringByReplacingOccurrencesOfString:@"/var/" withString:@"/var//./"]
    ];
    Method method = class_getInstanceMethod(NSURL.class, @selector(URLByStandardizingPath));
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^NSURL *(NSURL *url) {
        if ([url.path containsString:identifier]) {
            XCTFail(@"Audio-open identity must not use filesystem-aware path normalization");
            return url;
        }
        return ((NSURL *(*)(id, SEL))original)(url, @selector(URLByStandardizingPath));
    });
    method_setImplementation(method, replacement);
    @try {
        for (NSString *alias in aliases) {
            NSURL *url = [NSURL fileURLWithPath:alias isDirectory:NO];
            XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(url), path, @"%@", alias);
        }
        NSURL *otherPrivateRoot = [NSURL fileURLWithPath:@"/private/music/track.flac" isDirectory:NO];
        XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(otherPrivateRoot), @"/private/music/track.flac");
    } @finally {
        method_setImplementation(method, original);
        imp_removeBlock(replacement);
    }
}

@end

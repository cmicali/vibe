//
// Standardized-path identity for bounded audio-open claims, the
// delivery/detach race, the tail a stream fetches ahead, and which mount
// reads ahead.
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#import "AudioFileOpenRules.h"

@interface AudioFileOpenRulesTests : XCTestCase
@end

@implementation AudioFileOpenRulesTests

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

- (void)testDetachWinsBeforeQueuedDeliveryBegins {
    VibeAudioFileOpenDeliveryState state = VibeAudioFileOpenDeliveryWaiting;
    XCTAssertTrue(VibeAudioFileOpenDetachDelivery(&state));
    XCTAssertFalse(VibeAudioFileOpenBeginDelivery(&state));
    XCTAssertEqual(state, VibeAudioFileOpenDeliveryDetached);
}

- (void)testDeliveryAlreadyRunningCannotBeRetracted {
    VibeAudioFileOpenDeliveryState state = VibeAudioFileOpenDeliveryWaiting;
    XCTAssertTrue(VibeAudioFileOpenBeginDelivery(&state));
    XCTAssertFalse(VibeAudioFileOpenDetachDelivery(&state));
    XCTAssertEqual(state, VibeAudioFileOpenDeliveryRunning);
}

// What each format's open reads at the end, with room: a small window for
// every head-and-trailer format, unknown ones too; an MP4's moov scaled with
// the file between its floor and its cap; none for a file no bigger than twice
// its window.
- (void)testTheTailWindowIsSizedPerFormat {
    const uint64_t KB = 1024, MB = 1024 * KB;
    for (NSString *extension in @[@"mp3", @"MP3", @"flac", @"wav", @"aiff", @"aif", @"w64", @"caf", @"ogg", @"xyz", @""]) {
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 300 * MB), 128 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 256 * KB + 1), 128 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 256 * KB), 0u, @"%@: at twice the window", extension);
    }
    XCTAssertEqual(VibeAudioFileTailWindowBytes(@"mp3", 0), 0u);
    for (NSString *extension in @[@"m4a", @"M4A", @"m4b", @"m4r", @"mp4", @"qta"]) {
        // 6 minutes of 256 kbps AAC, its moov ~60 KB: the floor.
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 11 * MB), 512 * KB, @"%@", extension);
        // A 32nd of the file between the two.
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 32 * MB), 1 * MB, @"%@", extension);
        // An hour of 128 kbps (57 MB, moov 608 KB) and a two-hour mix (moov
        // ~1.2 MB) both fit under the cap, 1.5 MB, reached from 48 MB.
        XCTAssertGreaterThan(VibeAudioFileTailWindowBytes(extension, 57 * MB), 2 * 608 * KB, @"%@", extension);
        XCTAssertGreaterThan(VibeAudioFileTailWindowBytes(extension, 115 * MB), 120 * 10 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 48 * MB), 1536 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 300 * MB), 1536 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 1 * MB + 1), 512 * KB, @"%@", extension);
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 1 * MB), 0u, @"%@: at twice the floor", extension);
    }
}

#pragma mark - The mount rule

// A fake getfsstat table: each mount's name, local or not.
static NSData *VibeMountTable(NSDictionary<NSString *, NSNumber *> *mounts) {
    NSMutableData *table = [NSMutableData dataWithLength:mounts.count * sizeof(struct statfs)];
    struct statfs *entries = table.mutableBytes;
    NSUInteger i = 0;
    for (NSString *name in mounts) {
        strlcpy(entries[i].f_mntonname, name.fileSystemRepresentation, sizeof(entries[i].f_mntonname));
        entries[i].f_flags = mounts[name].boolValue ? MNT_LOCAL : MNT_DONTBROWSE;
        i++;
    }
    return table;
}

static BOOL VibeReadsAheadIn(NSData *table, NSString *path) {
    return VibeMountReadsAhead(table.bytes, (int)(table.length / sizeof(struct statfs)), path) != NULL;
}

// The longest mount name that is a whole-component prefix decides, and
// MNT_LOCAL alone says local; root holds what nothing else does.
- (void)testTheLongestMountPrefixDecidesAndMNTLocalSaysLocal {
    NSData *table = VibeMountTable(@{@"/": @YES, @"/Volumes/Media": @NO, @"/Volumes/Media/Local": @YES,
                                     @"/Volumes/Disk": @YES, @"/System/Volumes/Data": @YES});
    XCTAssertTrue(VibeReadsAheadIn(table, @"/Volumes/Media/Albums/a.flac"));
    XCTAssertTrue(VibeReadsAheadIn(table, @"/Volumes/Media"));
    XCTAssertFalse(VibeReadsAheadIn(table, @"/Volumes/Media/Local/a.flac"), @"a longer local mount inside wins");
    XCTAssertFalse(VibeReadsAheadIn(table, @"/Volumes/MediaPlus/a.flac"), @"a prefix is whole components");
    XCTAssertFalse(VibeReadsAheadIn(table, @"/Volumes/Disk/a.flac"));
    XCTAssertFalse(VibeReadsAheadIn(table, @"/Users/me/Music/a.flac"), @"root holds it, and root is local");
    int count = (int)(table.length / sizeof(struct statfs));
    int index = VibeMountHoldingPath(table.bytes, count, @"/Volumes/Media/Albums/a.flac");
    XCTAssertEqual(strcmp(((const struct statfs *)table.bytes)[index].f_mntonname, "/Volumes/Media"), 0);
}

// /var and /tmp are symlinks into /private, and either spelling of a path
// finds the mount named in the other, both ways, with nothing asked of the
// disk.
- (void)testTheVarAndTmpSpellingsMatchEitherWay {
    NSData *privateNames = VibeMountTable(@{@"/": @YES, @"/private/var/share": @NO, @"/private/tmp/share": @NO});
    XCTAssertTrue(VibeReadsAheadIn(privateNames, @"/var/share/a.flac"));
    XCTAssertTrue(VibeReadsAheadIn(privateNames, @"/private/var/share/a.flac"));
    XCTAssertTrue(VibeReadsAheadIn(privateNames, @"/tmp/share/a.flac"));
    XCTAssertFalse(VibeReadsAheadIn(privateNames, @"/var/other/a.flac"));
    XCTAssertFalse(VibeReadsAheadIn(privateNames, @"/variable/share/a.flac"), @"only /var itself is the alias");
    NSData *shortNames = VibeMountTable(@{@"/": @YES, @"/var/share/": @NO, @"/tmp/share": @NO});
    XCTAssertTrue(VibeReadsAheadIn(shortNames, @"/private/var/share/a.flac"), @"a trailing slash on a mount name too");
    XCTAssertTrue(VibeReadsAheadIn(shortNames, @"/private/tmp/share/a.flac"));
    XCTAssertTrue(VibeReadsAheadIn(shortNames, @"/tmp/share/a.flac"));
}

// A leading /System/Volumes/Data names the same place as the root, on a
// mount's name and on a path alike, and only as a whole component.
- (void)testTheDataVolumeSpellingMatchesEitherWay {
    NSData *table = VibeMountTable(@{@"/": @YES, @"/System/Volumes/Data": @YES, @"/System/Volumes/Data/home": @NO,
                                     @"/Volumes/Media": @NO});
    XCTAssertTrue(VibeReadsAheadIn(table, @"/home/me/a.flac"), @"the mount named under the data volume");
    XCTAssertTrue(VibeReadsAheadIn(table, @"/System/Volumes/Data/home/me/a.flac"));
    XCTAssertTrue(VibeReadsAheadIn(table, @"/System/Volumes/Data/Volumes/Media/a.flac"), @"the path named under it");
    XCTAssertFalse(VibeReadsAheadIn(table, @"/System/Volumes/Data/Users/me/a.flac"));
    XCTAssertFalse(VibeReadsAheadIn(table, @"/System/Volumes/Database/home/a.flac"), @"a prefix is whole components");
    NSData *aliased = VibeMountTable(@{@"/": @YES, @"/private/var/share": @NO});
    XCTAssertTrue(VibeReadsAheadIn(aliased, @"/System/Volumes/Data/private/var/share/a.flac"));
}

// No table, or no mount holding the path, is the direct road.
- (void)testNoMountIsTheDirectRoad {
    XCTAssertTrue(VibeMountReadsAhead(NULL, 0, @"/Volumes/Media/a.flac") == NULL);
    NSData *table = VibeMountTable(@{@"/Volumes/Media": @NO});
    XCTAssertFalse(VibeReadsAheadIn(table, @"/Users/me/a.flac"));
    XCTAssertEqual(VibeMountHoldingPath(table.bytes, 1, @"/Users/me/a.flac"), -1);
    XCTAssertTrue(VibeReadsAheadIn(VibeMountTable(@{@"/": @NO}), @"/Users/me/a.flac"), @"a network root holds every path");
}

@end

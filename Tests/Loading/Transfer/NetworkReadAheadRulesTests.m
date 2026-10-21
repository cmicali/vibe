#import <XCTest/XCTest.h>

#import "NetworkReadAheadRules.h"

@interface NetworkReadAheadRulesTests : XCTestCase
@end

@implementation NetworkReadAheadRulesTests

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

- (void)testNoMountIsTheDirectRoad {
    XCTAssertTrue(VibeMountReadsAhead(NULL, 0, @"/Volumes/Media/a.flac") == NULL);
    NSData *table = VibeMountTable(@{@"/Volumes/Media": @NO});
    XCTAssertFalse(VibeReadsAheadIn(table, @"/Users/me/a.flac"));
    XCTAssertEqual(VibeMountHoldingPath(table.bytes, 1, @"/Users/me/a.flac"), -1);
    XCTAssertTrue(VibeReadsAheadIn(VibeMountTable(@{@"/": @NO}), @"/Users/me/a.flac"), @"a network root holds every path");
}

@end

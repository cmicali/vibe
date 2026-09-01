//
// The suite is host-less and therefore UNSANDBOXED (Tests/CLAUDE.md) — which
// is what lets it read fixtures straight from the repo, and is not going to
// change. The cost is that any production path resolving a standard user
// directory answers with the DEVELOPER'S real ~/Library rather than a
// container: AppTheme's artwork store would create ~/Library/Application
// Support/ThemeArt, a generically named folder that does not even say Vibe.
//
// So the redirect is installed here, at image load, before XCTest has built a
// single case. It deliberately does NOT live in some test's setUp: a suite-
// wide guarantee that each class opts into is one a new class silently opts
// out of, which is exactly how the folder above got made.
//
// TRAP: a test that redirects the path for its own isolation must RESTORE
// this value afterwards, never unsetenv it — unsetting hands every test that
// runs later the real ~/Library, and the leak lands under whichever class
// happened to run next rather than the one that caused it.
//
// The same applies to NSUserDefaults, for a subtler reason. The suite has no
// bundle identifier of its own, so AppSettings writes land in the XCTEST
// TOOL's domain — ~/Library/Preferences/com.apple.dt.xctest.tool.plist,
// shared with every other XCTest run on the machine. Saving and restoring a
// setting around a test does not help: reading an unset key answers the
// REGISTERED default, so writing that value back materializes a key that was
// never on disk. The domain is therefore snapshotted here and restored at
// exit, which is the only place that can see "whatever any test wrote".
//

#import <Foundation/Foundation.h>

@interface VibeTestFilesystemGuard : NSObject
@end

@implementation VibeTestFilesystemGuard

static NSString *gRoot;
static NSString *gDefaultsDomain;
static NSDictionary *gDefaultsSnapshot;

static void VibeRestoreTestFilesystem(void) {
    [NSFileManager.defaultManager removeItemAtPath:gRoot error:NULL];
    // Back to exactly what was on disk before the first test ran — including
    // "no domain at all", which is what an empty snapshot restores.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removePersistentDomainForName:gDefaultsDomain];
    if (gDefaultsSnapshot.count) {
        [defaults setPersistentDomain:gDefaultsSnapshot forName:gDefaultsDomain];
    }
    [defaults synchronize];
}

+ (void)load {
    // Per process, so concurrent runs cannot delete each other's root at exit.
    gRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"VibeTests-%d", getpid()]];
    setenv("VIBE_THEME_ART_DIR",
           [gRoot stringByAppendingPathComponent:@"ThemeArt"].UTF8String, 1);

    gDefaultsDomain = NSBundle.mainBundle.bundleIdentifier ?: @"com.apple.dt.xctest.tool";
    gDefaultsSnapshot = [[NSUserDefaults.standardUserDefaults
            persistentDomainForName:gDefaultsDomain] copy];
    atexit(VibeRestoreTestFilesystem);
}

@end

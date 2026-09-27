// The suite is host-less and so unsandboxed (Tests/CLAUDE.md): a production
// path that resolves a standard user directory answers with the developer's
// real ~/Library. AppTheme's artwork store would land in ~/Library/Application
// Support/<main bundle identifier>/ThemeArt — here the XCTest tool's
// identifier. Installed at image load, not in a setUp, so no test class can
// opt out of it.
//
// TRAP: a test that narrows VIBE_THEME_ART_DIR must restore the previous
// value, never unsetenv it: unset, the store resolves the real ~/Library, and
// the leak lands under whichever class runs next.
//
// AppSettings writes land in the XCTest tool's shared defaults domain. Saving
// and restoring a setting around a test does not help: reading an unset key
// answers the registered default, so writing it back materializes a key that
// was never on disk. Only the exit-time domain restore sees what any test
// wrote.

#import <Foundation/Foundation.h>

@interface VibeTestFilesystemGuard : NSObject
@end

@implementation VibeTestFilesystemGuard

static NSString *gRoot;
static NSString *gDefaultsDomain;
static NSDictionary *gDefaultsSnapshot;

static void VibeRestoreTestFilesystem(void) {
    [NSFileManager.defaultManager removeItemAtPath:gRoot error:NULL];
    // An empty snapshot restores "no domain at all".
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

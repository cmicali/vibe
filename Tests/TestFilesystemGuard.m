// The suite is host-less and so unsandboxed (Tests/AGENTS.md): a production
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
// Standard defaults would be the XCTest tool's domain, shared by every test
// process on the machine: the parallel runner's clones and any concurrent
// `make test` would read each other's writes. So +standardUserDefaults answers
// a store of this process's own, held in memory. Saving and restoring a
// setting around a test would not do: reading an unset key answers the
// registered default, so writing it back materializes a key that was never
// stored.
//
// TRAP: in memory, not a cfprefsd-backed suite, even a per-pid one. On CI a
// suite key intermittently froze at its first value for seconds: later writes
// and removes read back the old dictionary while other keys wrote normally
// (OutputFormatRulesTests' carry, then SettingsRulesTests, in one process).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <errno.h>
#include <signal.h>

static NSString *gRoot;
static NSString *gToolDomain;
static NSString *gSuite;

// NSUserDefaults' typed accessors funnel through these three primitives.
// AppSettings reads its whole store by the main bundle's identifier, which
// here names the shared tool domain; answer this store instead.
@interface VibeTestUserDefaults : NSUserDefaults
@end

@implementation VibeTestUserDefaults {
    NSMutableDictionary<NSString *, id> *_stored;
    NSMutableDictionary<NSString *, id> *_registered;
}

- (instancetype)initWithSuiteName:(NSString *)suiteName {
    if ((self = [super initWithSuiteName:suiteName])) {
        _stored = [NSMutableDictionary dictionary];
        _registered = [NSMutableDictionary dictionary];
    }
    return self;
}

- (id)objectForKey:(NSString *)defaultName {
    @synchronized (self) {
        return _stored[defaultName] ?: _registered[defaultName];
    }
}

// A deep immutable copy, as cfprefsd stores it: a caller mutating what it
// wrote must not change what is read back.
- (void)setObject:(id)value forKey:(NSString *)defaultName {
    if (!value) {
        [self removeObjectForKey:defaultName];
        return;
    }
    id copy = CFBridgingRelease(CFPropertyListCreateDeepCopy(
            kCFAllocatorDefault, (__bridge CFPropertyListRef)value, kCFPropertyListImmutable));
    if (!copy) {
        [NSException raise:NSInvalidArgumentException
                    format:@"non-property-list value for key %@", defaultName];
    }
    @synchronized (self) {
        _stored[defaultName] = copy;
    }
}

- (void)removeObjectForKey:(NSString *)defaultName {
    @synchronized (self) {
        [_stored removeObjectForKey:defaultName];
    }
}

- (void)registerDefaults:(NSDictionary<NSString *, id> *)registrationDictionary {
    @synchronized (self) {
        [_registered addEntriesFromDictionary:registrationDictionary];
    }
}

- (NSDictionary<NSString *, id> *)persistentDomainForName:(NSString *)domainName {
    if (![domainName isEqualToString:gToolDomain]) {
        return [super persistentDomainForName:domainName];
    }
    @synchronized (self) {
        return [_stored copy];
    }
}

@end

@interface VibeTestFilesystemGuard : NSObject
@end

@implementation VibeTestFilesystemGuard

static void VibeRestoreTestFilesystem(void) {
    [NSFileManager.defaultManager removeItemAtPath:gRoot error:NULL];
}

// TRAP: atexit never runs in a process that crashes or is killed (a hang, a
// runner's teardown), so its root outlives it. Each process removes the roots
// of pids that are gone; a live pid's root, another run's, is left alone.
static void VibeRemoveOrphanedTestRoots(NSString *temporary) {
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *name in [files contentsOfDirectoryAtPath:temporary error:NULL]) {
        if (![name hasPrefix:@"VibeTests-"]) continue;
        pid_t pid = [name substringFromIndex:@"VibeTests-".length].intValue;
        if (pid <= 0 || ![name isEqualToString:[NSString stringWithFormat:@"VibeTests-%d", pid]]) continue;
        if (kill(pid, 0) == 0 || errno != ESRCH) continue;
        [files removeItemAtPath:[temporary stringByAppendingPathComponent:name] error:NULL];
    }
}

+ (void)load {
    // Per process, so concurrent runs cannot delete each other's root at exit.
    VibeRemoveOrphanedTestRoots(NSTemporaryDirectory());
    gRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"VibeTests-%d", getpid()]];
    [NSFileManager.defaultManager createDirectoryAtPath:gRoot
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    setenv("VIBE_THEME_ART_DIR",
           [gRoot stringByAppendingPathComponent:@"ThemeArt"].UTF8String, 1);

    // TRAP: anything not overridden falls through to an absolute-path suite,
    // not a named one. A named suite's plist is written into
    // ~/Library/Preferences by cfprefsd after the process has gone, so no
    // exit-time delete can reach it; this one is inside the root.
    gToolDomain = NSBundle.mainBundle.bundleIdentifier ?: @"com.apple.dt.xctest.tool";
    gSuite = [gRoot stringByAppendingPathComponent:@"defaults"];
    NSUserDefaults *defaults = [[VibeTestUserDefaults alloc] initWithSuiteName:gSuite];
    method_setImplementation(
            class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)),
            imp_implementationWithBlock(^NSUserDefaults *(id self) { return defaults; }));
    atexit(VibeRestoreTestFilesystem);
}

@end

//
//  FilePaths.m
//  Vibe
//

#import "FilePaths.h"

NSString *VibeAliasFreePath(NSString *path) {
    static NSString *const kDataVolumePrefix = @"/System/Volumes/Data/";
    // /private itself is real; only these roots are aliases.
    static NSArray<NSString *> *privateRoots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        privateRoots = @[@"/private/tmp", @"/private/var", @"/private/etc"];
    });
    if ([path hasPrefix:kDataVolumePrefix]) {
        path = [path substringFromIndex:kDataVolumePrefix.length - 1];
    }
    if (![path hasPrefix:@"/private/"]) {
        return path;
    }
    for (NSString *privateRoot in privateRoots) {
        if ([path isEqualToString:privateRoot] ||
                [path hasPrefix:[privateRoot stringByAppendingString:@"/"]]) {
            return [path substringFromIndex:@"/private".length];
        }
    }
    return path;
}

// TRAP: never stringByStandardizingPath here. It stats the path to decide
// whether to drop /private, and on a provider's folder that stat is IPC on
// whichever thread asked: the Files browser named and compared folders with
// it on main as each one opened.
NSString *VibeComparablePath(NSString *path) {
    if (!path) {
        return nil;
    }
    // Only a path with something to resolve pays for the URL round trip.
    BOOL resolves = [path containsString:@"/."] || [path containsString:@"//"]
            || (path.length > 1 && [path hasSuffix:@"/"]);
    NSString *standard = path;
    if (resolves) {
        standard = [NSURL fileURLWithPath:path isDirectory:NO].standardizedURL.path ?: path;
        standard = [NSString pathWithComponents:standard.pathComponents];
    }
    return VibeAliasFreePath(standard);
}

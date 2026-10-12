//
//  AppThemeTestCase.m
//

#import "AppThemeTestCase.h"

NSData *SquarePNG(NSInteger side) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:side pixelsHigh:side
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

@implementation AppThemeTestCase

// A directory per test, so one test's stored images cannot be found by the
// next. The suite-wide redirect (TestFilesystemGuard.m) is already in force;
// this narrows it rather than establishing it.
- (void)setUp {
    _suiteArtDir = @(getenv("VIBE_THEME_ART_DIR") ?: "");
    _artDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"VibeThemeArtTest-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    setenv("VIBE_THEME_ART_DIR", _artDir.UTF8String, 1);
}

- (void)tearDown {
    [_editingSettings factoryReset];
    [NSFileManager.defaultManager removeItemAtPath:_artDir error:NULL];
    // TRAP: restore, never unsetenv. The suite is unsandboxed, so an unset
    // path resolves to the developer's real ~/Library, and the file lands
    // under whichever test class runs next, not this one.
    setenv("VIBE_THEME_ART_DIR", _suiteArtDir.UTF8String, 1);
}

@end

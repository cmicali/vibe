//
//  AppThemeTestCase.h
//
//  The harness the AppTheme tests share: a per-test artwork directory and
//  the square PNG the image tests store. It runs no tests. AppThemeTests,
//  AppThemeArchiveTests and AppThemeStoreTests subclass it.
//

#import <XCTest/XCTest.h>

#import "AppTheme.h"
#import "SettingsRules.h"
#import "AppTheme+Archive.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AppSettingsInternal.h"
#import "TestFilesystemGuard.h"
#import "PlatformColor.h"
#import "SettingsThemesViewController+Editor.h"

NS_ASSUME_NONNULL_BEGIN

NSData *VibeSquarePNG(NSInteger side);

@interface AppThemeTestCase : XCTestCase {
@protected
    NSString *_artDir;
    NSString *_suiteArtDir;
    // Set by the store tests. tearDown factory-resets it.
    AppSettings *_editingSettings;
}
@end

NS_ASSUME_NONNULL_END

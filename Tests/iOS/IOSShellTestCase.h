//
//  IOSShellTestCase.h
//
//  The harness the iOS shell's model tests share: FolderSession and the
//  Locations, Favorites and Recents stores, over a per-test temp root. It
//  runs no tests.
//
//  The shell reaches DropboxMirror.shared, which here answers a store of the
//  process's own under its temp root: no account, no network, and nothing
//  under ~/Library. TestFilesystemGuard redirects LinkStore.shared the same
//  way. The stores' own singletons are emptied before each test, because they
//  live as long as the process.
//

#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

@interface IOSShellTestCase : XCTestCase

// Resolved with realpath(3), so a walk's paths and these agree.
@property (nonatomic, readonly) NSURL *root;

// A directory under root, with intermediates.
- (NSURL *)folder:(NSString *)relativePath;
// A nonempty file under root, which a walk lists by its extension.
- (NSURL *)file:(NSString *)relativePath;

// Spins main until the condition holds or the hang guard runs out.
- (BOOL)eventually:(BOOL (^)(void))condition;
// Spins main for the negative-check window.
- (void)settle;

@end

NS_ASSUME_NONNULL_END

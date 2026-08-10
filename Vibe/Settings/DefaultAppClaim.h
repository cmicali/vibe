//
//  DefaultAppClaim.h
//  Vibe
//
//  Settings > General's default-player button: asking Launch Services to make
//  Vibe the default app for every audio type DocumentTypes declares, so the
//  user need not walk Finder's Get Info > Open With > Change All once per
//  extension. The type list itself lives in DocumentTypes (Common); this is
//  the NSWorkspace half, macOS-only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DefaultAppClaim : NSObject

// Answers YES when Vibe is already the default app for every
// declaredFileTypes entry. The per-type Launch Services lookups are
// synchronous XPC calls, so the walk runs on a background queue; the
// completion arrives on the main thread.
+ (void)checkIsDefaultAppForAllFileTypes:(void (^)(BOOL isDefault))completion;

// Requests default-app status for every declaredFileTypes entry. It returns
// immediately: the system asks the user to confirm and reports the outcome
// itself, and the result shows up in checkIsDefaultAppForAllFileTypes: and in
// the log.
+ (void)makeDefaultApp;

@end

NS_ASSUME_NONNULL_END

//
//  DefaultAppRegistration.h
//  Vibe
//
//  The NSWorkspace half of DocumentTypes: Settings > General's default-player
//  button.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DefaultAppRegistration : NSObject

// YES when Vibe is the default app for every declaredFileTypes entry. Walks
// off main; the completion arrives on main.
+ (void)checkIsDefaultAppForAllFileTypes:(void (^)(BOOL isDefault))completion;

// Returns immediately; the system confirms with the user and reports the
// outcome itself.
+ (void)makeDefaultApp;

@end

NS_ASSUME_NONNULL_END

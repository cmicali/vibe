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

// YES when Vibe is the default app for every type it claims: each
// Default-rank declaration — the audio, CUE sheets and M3U playlists — and
// the type each of its extensions resolves to.
// Walks off main; the completion arrives on main.
+ (void)checkIsDefaultAppForAllFileTypes:(void (^)(BOOL isDefault))completion;

// Asks for each claimed type not already Vibe's, one system prompt at a time.
// A refusal or a "Keep" costs only its own type. The completion arrives on
// main once every request has answered; `refused` is YES when the system
// refused them all without the user declining one, as a sandboxed caller can
// be refused, and the user must use the Finder instead.
+ (void)makeDefaultAppWithCompletion:(void (^)(BOOL refused))completion;

@end

NS_ASSUME_NONNULL_END

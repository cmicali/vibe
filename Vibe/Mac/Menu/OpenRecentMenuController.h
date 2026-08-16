//
//  OpenRecentMenuController.h
//  Vibe
//
//  Owns the File > Open Recent submenu's live content. It rebuilds the submenu
//  from NSDocumentController's recentDocumentURLs each time the menu opens,
//  with a Clear Menu item at the bottom, and the recent-file items target the
//  app delegate's openRecentDocument:. MainMenuBuilder builds the submenu's
//  slot and wires this controller as its delegate, and the app delegate owns
//  it, because menu delegates are weak. That is the pattern throughout: one
//  per-menu controller per live menu, owned by the object it works for, as
//  with OutputDevicesMenuController.
//

#import <Cocoa/Cocoa.h>

@class AppDelegate;

NS_ASSUME_NONNULL_BEGIN

@interface OpenRecentMenuController : NSObject <NSMenuDelegate>

- (instancetype)initWithAppDelegate:(AppDelegate *)appDelegate;

@end

NS_ASSUME_NONNULL_END

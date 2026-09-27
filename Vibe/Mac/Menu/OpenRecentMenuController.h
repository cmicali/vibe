//
//  OpenRecentMenuController.h
//  Vibe
//
//  File > Open Recent, rebuilt from NSDocumentController's recentDocumentURLs
//  on every open. The app delegate owns it: menu delegates are weak.
//

#import <Cocoa/Cocoa.h>

@class AppDelegate;

NS_ASSUME_NONNULL_BEGIN

@interface OpenRecentMenuController : NSObject <NSMenuDelegate>

- (instancetype)initWithAppDelegate:(AppDelegate *)appDelegate;

@end

NS_ASSUME_NONNULL_END

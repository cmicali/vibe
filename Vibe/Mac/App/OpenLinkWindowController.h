//
//  OpenLinkWindowController.h
//  Vibe
//
//  File > Open URL…'s window. The app delegate owns one for the app's life.
//  The window is built at each show and released at each close.
//

#import <Cocoa/Cocoa.h>

@class AppDelegate;

NS_ASSUME_NONNULL_BEGIN

@interface OpenLinkWindowController : NSObject <NSMenuItemValidation, NSWindowDelegate, NSTextFieldDelegate>

// The link opens through appDelegate's openLinkString:completion:.
- (instancetype)initWithAppDelegate:(AppDelegate *)appDelegate;

// The window while it is up, else nil.
@property (nonatomic, readonly, nullable) NSPanel *window;

// Fronts the player, then the window. A second ⌘U re-fronts the window.
- (void)showWindow:(nullable id)sender;

- (IBAction)closeFile:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END

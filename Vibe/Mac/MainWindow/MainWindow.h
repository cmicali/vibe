//
//  MainWindow.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "MainWindowLayout.h" // window-layout constants (kMainWindowContentWidth etc.)

NS_ASSUME_NONNULL_BEGIN

@protocol FileDropDelegate;

@interface MainWindow : NSWindow <NSDraggingDestination>

@property (nullable, weak) id <FileDropDelegate> dropDelegate;

- (BOOL)isPlaylistShown;

- (void)setSmallSize:(BOOL)animate;
- (void)setLargeSize:(BOOL)animate;

// The window minus the pitch panel's slice: what View > Width sets and checks.
@property (readonly) CGFloat contentWidth;
- (void)setContentWidth:(CGFloat)width animate:(BOOL)animate;

// The frame slid left so a right-edge growth stays on screen; unchanged while
// the position is locked.
- (NSRect)frameKeptOnScreen:(NSRect)frame;

- (IBAction)toggleSize:(id)sender;

// The height a drag may rest at; the delegate's windowWillResize: applies it.
- (CGFloat)restingHeightForDraggedHeight:(CGFloat)height;

// The window grows by kPitchPanelWidth to reveal the panel parked past its
// right edge.
- (BOOL)isPitchPanelShown;
- (void)setPitchPanelShown:(BOOL)shown animate:(BOOL)animate;

// The first-launch shape. Call MainPlayerController.resetWindowToDefaultShape
// instead: alone, this leaves the pitch panel on screen, its right-anchored
// mask riding the shrinking edge.
- (void)resetToDefaultShape;

@end

@protocol FileDropDelegate <NSObject>

// Whether a drop at this window point appends rather than replaces, which the
// empty-state wells decide. Answered synchronously, at drop time.
- (BOOL)mainWindow:(MainWindow *)mainWindow dropAppendsAtLocation:(NSPoint)location;

// Drag-over tracking for the wells, in window coordinates. Ended fires on exit
// and after a drop.
- (void)mainWindow:(MainWindow *)mainWindow fileDraggingUpdatedAtLocation:(NSPoint)location;
- (void)mainWindowFileDraggingEnded:(MainWindow *)mainWindow;

@end

NS_ASSUME_NONNULL_END

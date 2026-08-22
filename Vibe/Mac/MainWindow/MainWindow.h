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

// The player body's width: the window minus the pitch panel's slice. This is
// what the View > Size presets set and what their checkmarks compare against,
// so the number means the same thing whether or not the panel is out.
@property (readonly) CGFloat contentWidth;
- (void)setContentWidth:(CGFloat)width animate:(BOOL)animate;

- (IBAction)toggleSize:(id)sender;

// The height a drag-resize is allowed to rest at, given the one it is asking
// for. The controller, as the window delegate, funnels windowWillResize:
// through this; the rule lives here with the rest of the frame geometry.
- (CGFloat)restingHeightForDraggedHeight:(CGFloat)height;

// The slide-out pitch panel. The window grows by kPitchPanelWidth to the right
// to reveal the panel view the controller parked past the content's right edge.
- (BOOL)isPitchPanelShown;
- (void)setPitchPanelShown:(BOOL)shown animate:(BOOL)animate;

// The shape a first launch would have: both panes hidden, the design width,
// the collapsed height. The frame half of Factory reset — call
// MainPlayerController.resetWindowToDefaultShape instead, which follows it
// with the sibling frames; this alone leaves the pitch panel on screen at the
// new width, since its right-anchored mask rides the shrinking edge.
- (void)resetToDefaultShape;

@end

@protocol FileDropDelegate <NSObject>
@optional

// Whether a drop at this point — NSDraggingInfo.draggingLocation, in window
// coordinates — appends rather than replaces, which the playlist's empty-state
// wells decide. Answered synchronously, at drop time, because the wells are
// geometry and the URLs then travel the app's ordinary open funnel, which knows
// only append-or-replace.
- (BOOL)mainWindow:(MainWindow *)mainWindow dropAppendsAtLocation:(NSPoint)location;

// Drag-over tracking for the empty-state wells, again in window coordinates.
// The updated callback fires on every entered and updated event. The ended
// callback fires both on exit and after a drop, and receivers treat it as an
// instruction to leave the drag-over presentation.
- (void)mainWindow:(MainWindow *)mainWindow fileDraggingUpdatedAtLocation:(NSPoint)location;
- (void)mainWindowFileDraggingEnded:(MainWindow *)mainWindow;

@end

NS_ASSUME_NONNULL_END

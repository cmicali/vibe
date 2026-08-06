//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "Constants.h" // window-layout constants (kMainWindowContentWidth etc.)

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

@end

@protocol FileDropDelegate <NSObject>
@optional

// location is the drop point, NSDraggingInfo.draggingLocation in window
// coordinates, which the playlist's empty-state wells resolve into their
// replace or add actions. It is delivered asynchronously, after directory
// expansion.
- (void)mainWindow:(MainWindow *)mainWindow filesDropped:(NSArray<NSURL *>*)urls
        atLocation:(NSPoint)location;

// Drag-over tracking for the empty-state wells, again in window coordinates.
// The updated callback fires on every entered and updated event. The ended
// callback fires both on exit and after a drop, and receivers treat it as an
// instruction to leave the drag-over presentation.
- (void)mainWindow:(MainWindow *)mainWindow fileDraggingUpdatedAtLocation:(NSPoint)location;
- (void)mainWindowFileDraggingEnded:(MainWindow *)mainWindow;

@end

NS_ASSUME_NONNULL_END

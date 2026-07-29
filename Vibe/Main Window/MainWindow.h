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

// The player body's width: the window minus the pitch panel's slice. What the
// View > Size presets set and what their checkmarks compare against, so the
// number means the same thing whether or not the panel is out.
@property (readonly) CGFloat contentWidth;
- (void)setContentWidth:(CGFloat)width animate:(BOOL)animate;

- (IBAction)toggleSize:(id)sender;

// Slide-out pitch panel: the window grows kPitchPanelWidth to the right to
// reveal the panel view the controller parked past the content's right edge.
- (BOOL)isPitchPanelShown;
- (void)setPitchPanelShown:(BOOL)shown animate:(BOOL)animate;

@end

@protocol FileDropDelegate <NSObject>
@optional

// location = the drop point (NSDraggingInfo.draggingLocation, window
// coordinates): the playlist empty-state wells resolve it into their
// replace/add actions. Delivered async after directory expansion.
- (void)mainWindow:(MainWindow *)mainWindow filesDropped:(NSArray<NSURL *>*)urls
        atLocation:(NSPoint)location;

// Drag-over tracking for the empty-state wells, again in window coordinates.
// Updated fires on every entered/updated event; ended fires on exit AND after
// a drop (receivers treat it as "leave the drag-over presentation").
- (void)mainWindow:(MainWindow *)mainWindow fileDraggingUpdatedAtLocation:(NSPoint)location;
- (void)mainWindowFileDraggingEnded:(MainWindow *)mainWindow;

@end

NS_ASSUME_NONNULL_END

//
// Created by Christopher Micali on 7/29/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

// What a drop on the drop-zone UI should do, resolved from the drop point.
typedef NS_ENUM(NSInteger, PlaylistDropWellAction) {
    // Outside the wells (or the wells aren't visible) — callers fall back to
    // the window-wide default drop behavior.
    PlaylistDropWellActionNone,
    PlaylistDropWellActionReplace,
    PlaylistDropWellActionAdd,
};

NS_ASSUME_NONNULL_BEGIN

// The playlist pane's drop-target UI, spanning the pane in both playlist
// states:
//   - Empty playlist at rest: a Finder-style dashed well inviting a drag
//     (or ⌘O — clicking it sends openDocument: up the responder chain).
//   - Empty playlist, files dragged over the window: one full-width
//     "add to playlist" well (replace vs add is meaningless with no rows).
//   - Populated playlist, files dragged over: side-by-side replace/add wells
//     over a within-window blur so they read against the rows beneath.
//   - Populated playlist at rest: draws nothing and is hit-transparent.
//
// Presentation and hit-testing only: the WINDOW is the dragging destination
// (this view never registers for drags) — MainWindow forwards drag locations
// through MainPlayerController, and the drop resolves against the well
// geometry via dropActionForWindowPoint:.
@interface PlaylistDropZoneView : NSView

// Which layout the zone presents (see above). Set from the owning
// controller's updateUI funnel alongside the playlist count.
@property (nonatomic) BOOL playlistEmpty;

// Drag-over tracking; points are in window coordinates
// (NSDraggingInfo.draggingLocation). Updates enter the drag-over state and
// move the well highlight; no-ops while the view is hidden or collapsed.
- (void)fileDragUpdatedAtWindowPoint:(NSPoint)point;
- (void)fileDragEnded;

// Which well the given drop point lands on. Geometry-only (valid after
// fileDragEnded has already reset the drag-over state — drops are delivered
// async after directory expansion).
- (PlaylistDropWellAction)dropActionForWindowPoint:(NSPoint)point;

@end

NS_ASSUME_NONNULL_END

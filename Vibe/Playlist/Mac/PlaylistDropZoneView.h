//
//  PlaylistDropZoneView.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

// What a drop on the drop-zone UI should do, resolved from the drop point.
typedef NS_ENUM(NSInteger, PlaylistDropWellAction) {
    // Outside the wells, or the wells are not visible. Callers then fall back
    // to the window-wide default drop behavior.
    PlaylistDropWellActionNone,
    PlaylistDropWellActionReplace,
    PlaylistDropWellActionAdd,
};

NS_ASSUME_NONNULL_BEGIN

// The playlist pane's drop-target UI, spanning the pane in both playlist
// states:
//   - Empty playlist at rest: a Finder-style dashed well inviting a drag, or
//     a ⌘O; clicking it sends openDocument: up the responder chain.
//   - Empty playlist, with files dragged over the window: one full-width "add
//     to playlist" well, since replace against add is meaningless with no rows.
//   - Populated playlist, with files dragged over: side-by-side replace and add
//     wells over a within-window blur, so they read against the rows beneath.
//   - Populated playlist at rest: it draws nothing and is hit-transparent.
//
// This handles presentation and hit-testing alone. The window is the dragging
// destination, and this view never registers for drags. MainWindow forwards
// drag locations through MainPlayerController, and the drop resolves against
// the well geometry through dropActionForWindowPoint:.
@interface PlaylistDropZoneView : NSView

// Which layout the zone presents; see above. The owning controller sets it
// from its updateUI funnel, alongside the playlist count.
@property (nonatomic) BOOL playlistEmpty;

// Drag-over tracking. The points are in window coordinates, from
// NSDraggingInfo.draggingLocation. An update enters the drag-over state and
// moves the well highlight, and no-ops while the view is hidden or collapsed.
- (void)fileDragUpdatedAtWindowPoint:(NSPoint)point;
- (void)fileDragEnded;

// Which well the given drop point lands on. It is geometry-only, and so stays
// valid after fileDragEnded has already reset the drag-over state, which
// matters because drops are delivered asynchronously, after directory
// expansion.
- (PlaylistDropWellAction)dropActionForWindowPoint:(NSPoint)point;

@end

NS_ASSUME_NONNULL_END

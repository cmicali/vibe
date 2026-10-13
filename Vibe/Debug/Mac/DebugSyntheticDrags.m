//
//  DebugSyntheticDrags.m
//  Vibe
//
//  File drops and row reorders, delivered through the shipping delegates
//  with no drag session.
//

#import "DebugInternal.h"
#import "PlaylistTableView.h"
#import "LinkDropRules.h"

#if DEBUG

#pragma mark Synthetic file drags

// file_drag_hover, file_drag_drop and file_drag_end drive the FileDropDelegate
// path a real external file drag takes through MainWindow, as direct delegate
// calls with no mouse events or NSDraggingSession: mouse handlers can start
// window-server dragging, which unattended stress must avoid. Coordinates are
// the mouse verbs'. file_drag_drop takes a link too, dropped as text.

static NSString *VibeWellName(PlaylistDropWellAction action) {
    switch (action) {
        case PlaylistDropWellActionReplace: return @"replace";
        case PlaylistDropWellActionAdd:     return @"add";
        case PlaylistDropWellActionNone:    return @"none";
    }
}

// Returns NO with *errorJSON set on a malformed pair.
static BOOL VibeDragPointArgument(NSArray<NSString *> *tokens, NSWindow *window,
                                  NSPoint *outLocation, double *outX, double *outY,
                                  NSString **errorJSON) {
    NSString *verb = tokens.firstObject;
    double x = 0, y = 0;
    if (tokens.count < 3 || !VibeParseDouble(tokens[1], &x) || !VibeParseDouble(tokens[2], &y)) {
        *errorJSON = VibeErrorJSON(@"usage: %@ <x> <y>%@", verb,
                [verb isEqualToString:@"file_drag_drop"] ? @" <file-directory-or-link>" : @"");
        return NO;
    }
    *outX = x;
    *outY = y;
    *outLocation = VibeWindowPointForContentPoint(window, x, y);
    return YES;
}

NSString *VibeSyntheticFileDragHover(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    MainWindow *window = (MainWindow *)controller.window;
    NSPoint location;
    double x, y;
    NSString *errorJSON = nil;
    if (!VibeDragPointArgument(tokens, window, &location, &x, &y, &errorJSON)) {
        return errorJSON;
    }
    [window.dropDelegate mainWindow:window fileDraggingUpdatedAtLocation:location];
    // What a drop here would do: the assertable part of the reply.
    PlaylistDropWellAction well = [controller.playerContentView.playlistDropZoneView
            dropActionForWindowPoint:location];
    return VibeJSONString(@{@"ok": @YES, @"posted": @"file_drag_hover",
                            @"x": @(x), @"y": @(y), @"well": VibeWellName(well)});
}

NSString *VibeSyntheticFileDragEnd(MainPlayerController *controller) {
    MainWindow *window = (MainWindow *)controller.window;
    [window.dropDelegate mainWindowFileDraggingEnded:window];
    return VibeJSONString(@{@"ok": @YES, @"posted": @"file_drag_end"});
}

NSString *VibeSyntheticFileDragDrop(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    MainWindow *window = (MainWindow *)controller.window;
    NSPoint location;
    double x, y;
    NSString *errorJSON = nil;
    if (!VibeDragPointArgument(tokens, window, &location, &x, &y, &errorJSON)) {
        return errorJSON;
    }
    if (tokens.count < 4) {
        return VibeErrorJSON(@"usage: file_drag_drop <x> <y> <file-directory-or-link>");
    }
    NSString *argument = [[tokens subarrayWithRange:NSMakeRange(3, tokens.count - 3)]
            componentsJoinedByString:@" "];
    NSString *path = argument.stringByExpandingTildeInPath;
    // A file as Finder drags one. Anything else as a browser's text.
    NSDictionary<NSString *, NSString *> *item;
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
        item = @{kVibeDropTypeFileURL: [NSURL fileURLWithPath:path].absoluteString};
    }
    else if (VibeLinkIsWebLink(VibeLinkURLFromString(argument))) {
        item = @{kVibeDropTypeText: argument};
        path = argument;
    }
    else {
        return VibeErrorJSON(@"no file or directory at '%@'", path);
    }
    // For the reply only, resolved before anything mutates; the delivery
    // below re-resolves it.
    PlaylistDropWellAction well = [controller.playerContentView.playlistDropZoneView
            dropActionForWindowPoint:location];
    // performDragOperation:'s order: the well's append flag, the open funnel,
    // then draggingEnded's teardown. The funnel owns the expansion and a
    // link's resolve, so this returns without waiting; poll dump_state for the
    // playlist. As with `open`, an ungranted path may be denied at read time.
    BOOL append = [window.dropDelegate mainWindow:window dropAppendsAtLocation:location];
    [window openDroppedItems:@[item] appending:append];
    [window.dropDelegate mainWindowFileDraggingEnded:window];
    return VibeJSONString(@{@"ok": @YES, @"dropping": path,
                            @"x": @(x), @"y": @(y), @"well": VibeWellName(well)});
}

#pragma mark Synthetic reorder drags

// The reorder verbs drive the playlist's row-reorder drag through the
// NSTableViewDataSource methods a real session calls, in the same order:
// writer per dragged row, willBegin, validate, accept, ended. No
// NSDraggingSession is started; a stand-in NSDraggingInfo carries the real
// table as draggingSource and what the real writers minted as its pasteboard.
// Everything downstream — token match, survivor resolution, slot arithmetic,
// the model move, table reconciliation, undo — is the shipping path. AppKit's
// half is not exercised: the drag threshold, which rows a gesture picks up,
// the insertion line, autoscroll. The session deliberately survives across
// commands, so another verb can mutate the playlist mid-drag — races no
// pointer can stage deterministically.

// The stand-in dragging info. Only draggingSource and draggingPasteboard are
// read by the reorder path; the rest of the protocol is inert.
@interface VibeDebugReorderDraggingInfo : NSObject <NSDraggingInfo>
@property (nonatomic, weak) id source;
@property (nonatomic, strong) NSPasteboard *pasteboard;
@end

@implementation VibeDebugReorderDraggingInfo
@synthesize numberOfValidItemsForDrop = _numberOfValidItemsForDrop;
@synthesize animatesToDestination = _animatesToDestination;
@synthesize draggingFormation = _draggingFormation;

- (NSWindow *)draggingDestinationWindow { return nil; }
- (NSDragOperation)draggingSourceOperationMask { return NSDragOperationMove; }
- (NSPoint)draggingLocation { return NSZeroPoint; }
- (NSPoint)draggedImageLocation { return NSZeroPoint; }
// Deprecated protocol members, inert, for conformance only.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (NSImage *)draggedImage { return nil; }
- (NSPasteboard *)draggingPasteboard { return self.pasteboard; }
- (id)draggingSource { return self.source; }
- (NSInteger)draggingSequenceNumber { return 1; }
- (void)slideDraggedImageTo:(NSPoint)screenPoint {}
- (NSArray<NSString *> *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination {
    return nil;
}
#pragma clang diagnostic pop
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)enumOpts
                                  forView:(NSView *)view
                                  classes:(NSArray<Class> *)classArray
                            searchOptions:(NSDictionary<NSPasteboardReadingOptionKey, id> *)searchOptions
                               usingBlock:(void (^)(NSDraggingItem *, NSInteger, BOOL *))block {}
- (NSSpringLoadingHighlight)springLoadingHighlight { return NSSpringLoadingHighlightNone; }
- (void)resetSpringLoading {}
@end

// One synthetic session at most, as with real drags. Statics rather than
// controller state: this is harness bookkeeping, and the controller's own
// session ivars are set and cleared by the real delegate calls.
static VibeDebugReorderDraggingInfo *vibeReorderInfo;
static NSPasteboard *vibeReorderPasteboard;

static void VibeReorderClearSession(void) {
    [vibeReorderPasteboard releaseGlobally];
    vibeReorderPasteboard = nil;
    vibeReorderInfo = nil;
}

// Ends a live synthetic session the way a real cancel would, so the
// controller's token and retained tracks are cleared through the same call.
static void VibeReorderEndSession(PlaylistController *playlist, NSDragOperation operation) {
    NSDraggingSession *noSession = nil;
    [playlist tableView:playlist.tableView draggingSession:noSession
           endedAtPoint:NSZeroPoint operation:operation];
    VibeReorderClearSession();
}

NSString *VibeReorderBegin(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    PlaylistController *playlist = controller.playlistController;
    NSTableView *table = playlist.tableView;
    if (!table) {
        return VibeErrorJSON(@"no playlist table");
    }
    if (tokens.count < 2) {
        return VibeErrorJSON(@"usage: reorder_begin <row> [row ...]");
    }
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    for (NSString *token in [tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]) {
        double row = 0;
        if (!VibeParseDouble(token, &row) || row < 0) {
            return VibeErrorJSON(@"usage: reorder_begin <row> [row ...]");
        }
        [rows addIndex:(NSUInteger)row];
    }
    // A leftover session would strand the controller's token; a real drag
    // cannot start while another is live, so neither can this one.
    if (vibeReorderInfo) {
        VibeReorderEndSession(playlist, NSDragOperationNone);
    }
    // Per dragged row, as AppKit asks; this mints the controller's session
    // token.
    NSMutableArray<id<NSPasteboardWriting>> *items = [NSMutableArray arrayWithCapacity:rows.count];
    __block NSUInteger refusedRow = NSNotFound;
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        id<NSPasteboardWriting> item = [playlist tableView:table
                                    pasteboardWriterForRow:(NSInteger)row];
        if (!item) {
            refusedRow = row;
            *stop = YES;
            return;
        }
        [items addObject:item];
    }];
    if (refusedRow != NSNotFound) {
        VibeReorderEndSession(playlist, NSDragOperationNone);
        return VibeErrorJSON(@"row %lu is not draggable", (unsigned long)refusedRow);
    }
    vibeReorderPasteboard = [NSPasteboard pasteboardWithUniqueName];
    [vibeReorderPasteboard clearContents];
    [vibeReorderPasteboard writeObjects:items];
    NSDraggingSession *noSession = nil;
    [playlist tableView:table draggingSession:noSession
       willBeginAtPoint:NSZeroPoint forRowIndexes:rows];
    vibeReorderInfo = [VibeDebugReorderDraggingInfo new];
    vibeReorderInfo.source = table;
    vibeReorderInfo.pasteboard = vibeReorderPasteboard;
    NSMutableArray<NSNumber *> *began = [NSMutableArray arrayWithCapacity:rows.count];
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        [began addObject:@(row)];
    }];
    return VibeJSONString(@{@"ok": @YES, @"rows": began});
}

static NSString *VibeReorderSlotArgument(NSArray<NSString *> *tokens, NSInteger *outSlot) {
    double slot = 0;
    if (tokens.count < 2 || !VibeParseDouble(tokens[1], &slot)) {
        return VibeErrorJSON(@"usage: %@ <slot>", tokens.firstObject);
    }
    *outSlot = (NSInteger)slot;
    return nil;
}

NSString *VibeReorderUpdate(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    PlaylistController *playlist = controller.playlistController;
    if (!vibeReorderInfo) {
        return VibeErrorJSON(@"no reorder session; run reorder_begin first");
    }
    NSInteger slot = 0;
    NSString *errorJSON = VibeReorderSlotArgument(tokens, &slot);
    if (errorJSON) {
        return errorJSON;
    }
    NSDragOperation operation = [playlist tableView:playlist.tableView
                                       validateDrop:vibeReorderInfo
                                        proposedRow:slot
                              proposedDropOperation:NSTableViewDropAbove];
    return VibeJSONString(@{@"ok": @YES, @"slot": @(slot),
                            @"operation": operation == NSDragOperationMove ? @"move" : @"none"});
}

NSString *VibeReorderDrop(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    PlaylistController *playlist = controller.playlistController;
    if (!vibeReorderInfo) {
        return VibeErrorJSON(@"no reorder session; run reorder_begin first");
    }
    NSInteger slot = 0;
    NSString *errorJSON = VibeReorderSlotArgument(tokens, &slot);
    if (errorJSON) {
        return errorJSON;
    }
    // AppKit's ordering: a drop is only delivered through a passing
    // validation, and the session ends either way — a refused slot slides
    // back, it does not keep dragging.
    NSTableView *table = playlist.tableView;
    BOOL dropped = NO;
    if ([playlist tableView:table validateDrop:vibeReorderInfo proposedRow:slot
      proposedDropOperation:NSTableViewDropAbove] == NSDragOperationMove) {
        dropped = [playlist tableView:table acceptDrop:vibeReorderInfo row:slot
                        dropOperation:NSTableViewDropAbove];
    }
    VibeReorderEndSession(playlist, dropped ? NSDragOperationMove : NSDragOperationNone);
    return VibeJSONString(@{@"ok": @YES, @"slot": @(slot), @"dropped": @(dropped)});
}

NSString *VibeReorderCancel(MainPlayerController *controller) {
    if (!vibeReorderInfo) {
        return VibeErrorJSON(@"no reorder session; run reorder_begin first");
    }
    VibeReorderEndSession(controller.playlistController, NSDragOperationNone);
    return VibeJSONString(@{@"ok": @YES, @"cancelled": @YES});
}

#endif

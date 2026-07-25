//
//  OpenRecentMenuController.m
//  Vibe
//

#import "OpenRecentMenuController.h"
#import "AppDelegate.h"

@implementation OpenRecentMenuController {
    __weak AppDelegate *_appDelegate;
}

- (instancetype)initWithAppDelegate:(AppDelegate *)appDelegate {
    self = [super init];
    if (self) {
        _appDelegate = appDelegate;
    }
    return self;
}

// Rebuilt from NSDocumentController each time the menu opens.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSArray<NSURL *> *urls = [[NSDocumentController sharedDocumentController] recentDocumentURLs];
    for (NSURL *url in urls) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:url.lastPathComponent
                                                      action:@selector(openRecentDocument:)
                                               keyEquivalent:@""];
        item.target = _appDelegate;
        item.representedObject = url;
        [menu addItem:item];
    }
    if (urls.count > 0) {
        [menu addItem:[NSMenuItem separatorItem]];
    }
    NSMenuItem *clear = [[NSMenuItem alloc] initWithTitle:@"Clear Menu"
                                                   action:@selector(clearRecentDocuments:)
                                            keyEquivalent:@""];
    clear.target = [NSDocumentController sharedDocumentController];
    [menu addItem:clear];
}

// Without this, AppKit's key-equivalent scan calls menuNeedsUpdate: — a full
// Open Recent rebuild — on every keyDown (same pattern as
// OutputDevicesMenuController). No Open Recent item carries a key equivalent.
- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(_Nullable id *_Nonnull)target action:(_Nullable SEL *_Nonnull)action {
    return NO;
}

@end

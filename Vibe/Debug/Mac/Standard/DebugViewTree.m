//
//  DebugViewTree.m
//  vibe-libs
//

#import "DebugViewTree.h"

#if DEBUG

#import "DebugWireFormat.h"
#import "NSImage+Util.h"
#import "NSURL+Hash.h"

static NSDictionary *VibeViewDictionary(NSView *view) {
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"class"] = view.className;
    node[@"address"] = [NSString stringWithFormat:@"%p", view];
    if (view.identifier.length) {
        node[@"id"] = view.identifier;
    }
    node[@"frame"] = NSStringFromRect(view.frame);
    if (view.isHidden) {
        node[@"hidden"] = @YES;
    }
    if (view.alphaValue < 1.0) {
        node[@"alpha"] = @(view.alphaValue);
    }
    if (view.autoresizingMask != NSViewNotSizable) {
        node[@"mask"] = [NSString stringWithFormat:@"0x%lx", (unsigned long)view.autoresizingMask];
    }
    if (view.subviews.count) {
        NSMutableArray *subviews = [NSMutableArray array];
        for (NSView *subview in view.subviews) {
            [subviews addObject:VibeViewDictionary(subview)];
        }
        node[@"subviews"] = subviews;
    }
    return node;
}

NSString *VibeViewTreeDump(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (NSWindow *window in NSApp.windows) {
        NSMutableDictionary *node = [NSMutableDictionary dictionary];
        node[@"class"] = window.className;
        node[@"address"] = [NSString stringWithFormat:@"%p", window];
        node[@"title"] = window.title ?: @"";
        node[@"frame"] = NSStringFromRect(window.frame);
        node[@"visible"] = @(window.isVisible);
        node[@"key"] = @(window.isKeyWindow);
        if (window.contentView) {
            node[@"contentView"] = VibeViewDictionary(window.contentView);
        }
        [windows addObject:node];
    }
    return VibeJSONString(@{@"windows": windows});
}

// The first 8 hex digits of a SHA-1 of the image's pixels at 1x, so a script
// can tell a redrawn swatch from an unchanged one. Draws a copy, so the
// image's own cached rendering is untouched.
static NSString *VibeImageDigest(NSImage *image) {
    NSBitmapImageRep *rep = (NSBitmapImageRep *)[[image copy] resizedImage:image.size].representations.firstObject;
    if (!rep) {
        return @"";
    }
    NSData *pixels = [NSData dataWithBytesNoCopy:rep.bitmapData
                                          length:(NSUInteger)(rep.bytesPerRow * rep.pixelsHigh)
                                    freeWhenDone:NO];
    return [pixels.sha1Hex substringToIndex:8];
}

NSArray *VibeMenuArray(NSMenu *menu) {
    // Delegate-built menus (Output, Open Recent, Themes) populate only when
    // displayed, and [menu update] alone does not call menuNeedsUpdate:.
    if ([menu.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) {
        [menu.delegate menuNeedsUpdate:menu];
    }
    // Validates as opening the menu would, so enabled and state are live.
    [menu update];
    NSMutableArray *items = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) {
            [items addObject:@{@"separator": @YES}];
            continue;
        }
        NSMutableDictionary *node = [NSMutableDictionary dictionary];
        node[@"title"] = item.title;
        if (item.identifier.length) {
            node[@"id"] = item.identifier;
        }
        if (item.keyEquivalent.length) {
            node[@"key"] = item.keyEquivalent;
            if (item.keyEquivalentModifierMask) {
                node[@"mods"] = [NSString stringWithFormat:@"0x%lx", (unsigned long)item.keyEquivalentModifierMask];
            }
        }
        if (item.action) {
            node[@"action"] = NSStringFromSelector(item.action);
        }
        node[@"enabled"] = @(item.isEnabled);
        // Still in itemArray but not on screen, e.g. Convert with conversion
        // disabled in Settings.
        if (item.isHidden) {
            node[@"hidden"] = @YES;
        }
        if (item.state != NSControlStateValueOff) {
            node[@"state"] = @(item.state);
        }
        if (item.image) {
            node[@"imageDigest"] = VibeImageDigest(item.image);
        }
        if (item.submenu) {
            node[@"items"] = VibeMenuArray(item.submenu);
        }
        [items addObject:node];
    }
    return items;
}

NSMenuItem *VibeFindMenuItem(NSMenu *menu, NSString *identifierOrTitle) {
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.identifier isEqualToString:identifierOrTitle] || [item.title isEqualToString:identifierOrTitle]) {
            return item;
        }
        if (item.submenu) {
            NSMenuItem *found = VibeFindMenuItem(item.submenu, identifierOrTitle);
            if (found) {
                return found;
            }
        }
    }
    return nil;
}

#endif

//
//  NSDockTile+Util.h
//  Vibe
//
//  The Dock tile, and the app icon behind it. Two images can stand in the
//  tile: the app icon — the bundle's, or a custom one composed onto the
//  icon grid — and the playing track's artwork composed the same way. All
//  three entry points are main-thread calls.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSDockTile (Util)

// Puts the app icon back in the tile — whichever NSApp.applicationIconImage
// holds at the time, so a custom app icon reads through.
+ (void)resetToAppIcon;

// Composes the artwork onto the icon grid off-main and installs it in the
// tile; a later call, or a reset, wins over a slower composition.
+ (void)setDockIcon:(NSImage *)image;

// The app's icon everywhere the system draws one — the Dock (while the tile
// shows it), the app switcher, the About surfaces: a square image composed
// onto the icon grid like the artwork tile, or nil for the bundle's own
// icon. Synchronous, so a caller can reset the tile right after.
+ (void)setAppIcon:(nullable NSImage *)image;

@end

NS_ASSUME_NONNULL_END

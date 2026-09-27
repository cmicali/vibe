//
//  NSDockTile+Util.h
//  Vibe
//
//  The Dock tile and the app icon behind it. Main thread only.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSDockTile (Util)

// Shows whatever NSApp.applicationIconImage holds now, so a custom icon reads
// through.
+ (void)resetToAppIcon;

// Shaped composes onto the icon grid off-main; a later call or a reset wins
// over a slower composition.
+ (void)setDockIcon:(NSImage *)image shaped:(BOOL)shaped;

// The app icon everywhere the system draws one; nil restores the bundle's.
// Synchronous, so a caller can reset the tile right after.
+ (void)setAppIcon:(nullable NSImage *)image shaped:(BOOL)shaped;

@end

NS_ASSUME_NONNULL_END

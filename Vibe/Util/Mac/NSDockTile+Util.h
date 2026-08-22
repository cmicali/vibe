//
//  NSDockTile+Util.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface NSDockTile (Util)

+ (void)resetToAppIcon;

+ (void)setDockIcon:(NSImage *)image;
@end
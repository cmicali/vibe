//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSDockTile+Util.h"

@implementation NSDockTile (Util)

+ (void) resetToAppIcon {
    NSDockTile *dockTile = [[NSApplication sharedApplication] dockTile];
    NSImage *image = [NSApplication sharedApplication].applicationIconImage;
    NSImageView *iv = [NSImageView imageViewWithImage:image];
    [[NSApplication sharedApplication] dockTile].contentView = iv;
    [dockTile display];
}

+ (void)setDockIcon:(NSImage*)image {

//    NSData *data = [NSData dataWithBytes:bytes length:length];
    NSDockTile *dockTile = [[NSApplication sharedApplication] dockTile];
//    NSImage *image = [[NSImage alloc] initWithData:data];

    CGFloat iconSize = 128;
    CGFloat margin = 14;
    CGFloat borderSize = 2;

    NSImageView *imageView = [NSImageView imageViewWithImage:image];
    imageView.frame = CGRectMake(margin, margin, iconSize - (margin*2), iconSize - (margin*2));
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    imageView.wantsLayer = YES;
    imageView.layer.cornerRadius = 8;
    imageView.layer.masksToBounds = YES;
    imageView.layer.borderColor = NSColor.blackColor.CGColor;
    imageView.layer.borderWidth = borderSize;

    NSView *appIconView = [[NSView alloc] initWithFrame:CGRectMake(0, 0, iconSize, iconSize)];
    [appIconView addSubview:imageView];

    dockTile.contentView = appIconView;
    [dockTile display];

}

@end
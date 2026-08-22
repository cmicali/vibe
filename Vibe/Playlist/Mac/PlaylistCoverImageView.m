//
//  PlaylistCoverImageView.m
//  Vibe
//

#import "PlaylistCoverImageView.h"


@implementation PlaylistCoverImageView {

}

+ (NSGradient*)gradient {
    static NSGradient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:0 green:0 blue:0 alpha:0.8],
                [NSColor colorWithRed:0 green:0 blue:0 alpha:0.2],
                [NSColor colorWithRed:0 green:0 blue:0 alpha:0.0]
        ]];
    });
    return instance;
}

- (void)drawImageOverlayInRect:(NSRect)rect {
    NSGradient *g = [PlaylistCoverImageView gradient];
    [g drawInRect:rect angle:90];
}

@end

//
//  VectorBallsView.h
//  Vibe
//
//  Old-school demoscene vectorballs: the word "VIBE" as a dot-matrix of
//  shaded spheres spinning in 3D, rendered with Metal.
//

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

@interface VectorBallsView : MTKView

// Re-scatters the balls and replays the fly-in intro animation.
- (void)restartIntro;

@end

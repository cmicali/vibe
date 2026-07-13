//
//  VectorBallsView.h
//  Vibe
//
//  Old-school demoscene vectorballs: the word "VIBE" as a dot-matrix of
//  shaded spheres spinning in 3D, rendered with Metal.
//

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

// The intro replays by rebuilding the whole view (AboutWindowController) —
// there is deliberately no restart API; mutating the instance buffer on a
// live view would race in-flight command buffers.
@interface VectorBallsView : MTKView

@end

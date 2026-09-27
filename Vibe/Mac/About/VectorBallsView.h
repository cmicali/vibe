//
//  VectorBallsView.h
//  Vibe
//
//  Demoscene vectorballs: "VIBE" as a dot matrix of shaded spheres spinning in
//  3D, on Metal.
//

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

// No restart API: mutating the instance buffer on a live view would race
// in-flight command buffers, so AboutWindowController rebuilds the view.
@interface VectorBallsView : MTKView

@end

//
//  VectorBallsView.h
//  Vibe
//
//  Demoscene vectorballs: "VIBE" as a dot matrix of shaded spheres spinning in
//  3D, on Metal.
//

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

// One per open: the intro runs from creation, and AboutWindowController drops
// the view at close.
@interface VectorBallsView : MTKView

@end

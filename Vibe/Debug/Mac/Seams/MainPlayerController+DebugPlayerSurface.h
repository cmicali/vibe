//
//  MainPlayerController+DebugPlayerSurface.h
//  Vibe
//
//  The controller's VibeDebugPlayerSurface conformance. A category of its own
//  because (Debug) is declaration-only: its accessors are implemented in
//  MainPlayerController.m, so an @implementation of that category would have
//  to define every one of them here.
//

#if DEBUG

#import "MainPlayerController.h"
#import "DebugPlayerSurface.h"

@interface MainPlayerController (DebugPlayerSurface) <VibeDebugPlayerSurface>
@end

#endif

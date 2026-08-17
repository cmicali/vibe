//
//  MainPlayerController+DebugPlayerSurface.h
//  Vibe
//
//  The controller's VibeDebugPlayerSurface conformance, so the cross-platform
//  verbs in Debug/DebugCommonVerbs.m and the shared consistency checks in
//  Debug/DebugConsistency.m are written once for this controller and the
//  iOS PlayerViewController alike.
//
//  A category of its own rather than part of (Debug), which is declaration-only
//  by design: the outlets it re-declares are synthesized in
//  MainPlayerController.m, so giving that category an @implementation would ask
//  the compiler for every one of them here.
//
//  Debug builds only.
//

#if DEBUG

#import "MainPlayerController.h"
#import "DebugPlayerSurface.h"

@interface MainPlayerController (DebugPlayerSurface) <VibeDebugPlayerSurface>
@end

#endif

//
//  OpenLinkWindowController+Debug.h
//  Vibe
//
//  Declaration-only: the implementation is in the class's own .m, which keeps
//  the shipping header free of #if DEBUG.
//

#if DEBUG

#import "OpenLinkWindowController.h"

@interface OpenLinkWindowController (Debug)
// YES while the window's link resolves.
- (BOOL)debugResolving;
@end

#endif

//
//  OpenURLSheetController+Debug.h
//  Vibe (iOS)
//
//  Declaration-only: the implementation is in the class's own .m, which keeps
//  the shipping header free of #if DEBUG.
//

#if DEBUG

#import "OpenURLSheetController.h"

// Production methods the channel drives.
@interface OpenURLSheetController (DebugSurface)
// Open's and Cancel's own actions.
- (void)openFromSheet;
- (void)cancelSheet;
@end

@interface OpenURLSheetController (Debug)
- (UITextView *)debugField;
- (BOOL)debugOpenEnabled;
@end

#endif

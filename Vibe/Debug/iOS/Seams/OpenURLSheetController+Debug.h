//
//  OpenURLSheetController+Debug.h
//  Vibe (iOS)
//
//  Declaration-only: the implementation is in the class's own .m, which keeps
//  the shipping header free of #if DEBUG.
//

#if DEBUG

#import "OpenURLSheetController.h"

@interface OpenURLSheetController (Debug)
- (UITextView *)debugField;
- (BOOL)debugOpenEnabled;
// Open's and Cancel's own actions.
- (void)openFromSheet;
- (void)cancelSheet;
@end

#endif

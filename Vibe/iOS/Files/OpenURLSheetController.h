//
//  OpenURLSheetController.h
//  Vibe (iOS)
//
//  Open URL's sheet, modeled on the mac's window: a field three lines tall
//  that wraps, the system's Paste under it, and Cancel and Open. Open is
//  disabled while the field is blank. Return is Open and never breaks the
//  line. The sheet is built at init. Its presenter owns the resolve and says
//  when one runs through `resolving`.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpenURLSheetController : NSObject

// openBlock gets the field's text, from Open or Return, only while Open is
// enabled. cancelBlock runs on Cancel and on a swipe down.
- (instancetype)initWithOpen:(void (^)(NSString *text))openBlock
                      cancel:(dispatch_block_t)cancelBlock NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// While a link resolves, the field and Open are disabled and the spinner
// turns.
@property (nonatomic) BOOL resolving;

- (void)presentFrom:(UIViewController *)presenter;

// Closes the sheet, then runs then. With the sheet not up, then runs at once.
- (void)dismissThen:(nullable dispatch_block_t)then;

@end

NS_ASSUME_NONNULL_END

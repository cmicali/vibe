//
//  NSTextField+Label.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSTextField (Label)

// A plain label: borderless, uneditable and clipping. Every text of the main
// window's header and its volume control is one.
+ (instancetype)labelWithFrame:(NSRect)frame;

@end

NS_ASSUME_NONNULL_END

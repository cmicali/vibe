//
//  PlaylistTextCell.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface PlaylistTextCell : NSTextFieldCell

// Drawn over every color in the string; nil draws the string as set.
// PlaylistRowView pushes it. The string keeps its own colors, so clearing it
// restores them.
@property (nonatomic, nullable) NSColor *rowTextColor;

@end

NS_ASSUME_NONNULL_END

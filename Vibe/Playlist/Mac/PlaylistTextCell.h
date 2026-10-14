//
//  PlaylistTextCell.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Marks a string's title run. PlaylistTableView sets it. The cell reads it.
extern NSAttributedStringKey const PlaylistTitleRunAttributeName;

@interface PlaylistTextCell : NSTextFieldCell

// The title color draws the title run. The artist color draws every other
// run. A nil color keeps a run as set. PlaylistRowView pushes them. The string
// keeps its own colors, so clearing them restores the string.
- (void)setRowTitleColor:(nullable NSColor *)titleColor artistColor:(nullable NSColor *)artistColor;

@end

NS_ASSUME_NONNULL_END

//
//  PlaylistTextCell.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Marks a string's title run. PlaylistTableView sets it; the cell reads it.
extern NSAttributedStringKey const PlaylistTitleRunAttributeName;

@interface PlaylistTextCell : NSTextFieldCell

// Drawn over the string's colors: the title color over its title run, the
// artist color over every other run, nil keeping a run as set. PlaylistRowView
// pushes them. The string keeps its own colors, so clearing restores them.
- (void)setRowTitleColor:(nullable NSColor *)titleColor artistColor:(nullable NSColor *)artistColor;

@end

NS_ASSUME_NONNULL_END

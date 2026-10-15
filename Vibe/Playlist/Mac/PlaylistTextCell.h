//
//  PlaylistTextCell.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Names the column a run belongs to, by its kVibeThemeColorPlaylist* base.
// PlaylistTableView sets it. The cell reads it.
extern NSAttributedStringKey const PlaylistColumnAttributeName;

@interface PlaylistTextCell : NSTextFieldCell

// By column base. A run whose column has no color keeps its own.
// PlaylistRowView pushes them. The string keeps its own colors, so clearing
// them restores the string.
- (void)setRowColors:(nullable NSDictionary<NSString *, NSColor *> *)colors;

@end

NS_ASSUME_NONNULL_END

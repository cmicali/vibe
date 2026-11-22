//
//  VibeTrackRow.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// One track as a row or the mini player draws it. The app fills it from its
// own model. Rows compare it by content to skip an unchanged render, so the
// thumbnail is compared by identity and the strings by value.
@interface VibeTrackRow : NSObject <NSCopying>
@property (nonatomic, copy, nullable) NSString *title;
// Nil or empty draws one line, the title, centred on its own.
@property (nonatomic, copy, nullable) NSString *subtitle;
// Nil draws the file tile.
@property (nonatomic, nullable) UIImage *thumbnail;
@property (nonatomic, copy, nullable) NSString *durationText;
// The gutter's text, such as the row's position. Nil leaves it empty.
@property (nonatomic, copy, nullable) NSString *numberText;
// The gutter's equalizer in place of the number. Loading outranks it, and
// is pushed on its own, since a transfer changes without the row.
@property (nonatomic, getter=isPlaying) BOOL playing;
@end

NS_ASSUME_NONNULL_END

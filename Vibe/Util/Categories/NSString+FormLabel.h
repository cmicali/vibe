//
//  NSString+FormLabel.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSString (FormLabel)

// The string as a grouped-row label: the form-layout colon dropped.
//
// A settings string is authored with the colon its form layout wants ("Output:",
// French "Sortie :") and the catalogs keep it that way, because that is the form
// most of the mac's panes actually draw. A grouped row — the mac's cards, every
// row on the iOS settings screens — puts the value in its own column and wants
// the bare noun. Both platforms ask here rather than each trimming its own way,
// so one rule covers the French no-break space and the fullwidth colon CJK uses.
@property (nonatomic, readonly) NSString *vibeFormLabel;

@end

NS_ASSUME_NONNULL_END

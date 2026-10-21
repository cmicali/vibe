//
//  NSURL+FilenameTitle.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSURL (FilenameTitle)

// The last path component without its extension, trimmed: what a tagless file
// records as its title, and a row's title until its metadata loads, so the row
// does not change when metadata arrives. Not standardized, which would stat
// the path.
@property (nonatomic, readonly) NSString *filenameTitle;

@end

NS_ASSUME_NONNULL_END

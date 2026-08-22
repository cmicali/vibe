//
//  ArtworkImageView.h
//  Vibe
//

#import "CrossfadingImageView.h"

@interface ArtworkImageView : CrossfadingImageView <NSDraggingSource>

@property (copy) NSURL *fileURL;

// The displayed track's singleLineTitle, for the copy_artist_title drag
// action. Reassigned with fileURL, so the two cannot name different tracks.
@property (copy) NSString *trackDisplayName;

@end

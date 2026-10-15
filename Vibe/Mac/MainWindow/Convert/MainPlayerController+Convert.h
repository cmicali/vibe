//
//  MainPlayerController+Convert.h
//  Vibe
//
//  Convert to FLAC's controller half: the shared funnel, the swap into the
//  source's rows, and the undo round trip. The engine is AudioFileConverter
//  (Mac/Convert/).
//

#import "MainPlayerController.h"

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Convert)

// On the current track; the window body's context menu shares it.
- (IBAction)convertCurrentTrackToFLAC:(nullable id)sender;

// The same item, re-aimed by validation while converting. A click after the
// conversion settles does nothing.
- (IBAction)cancelConversion:(nullable id)sender;

// completion runs after the swap and the disposal settle, reporting what the
// disposal did, so the convert_to_flac verb does not race the Trash.
- (void)convertTrackToFLAC:(AudioTrack *)track
                completion:(void (^_Nullable)(NSURL *_Nullable outputURL,
                                              BOOL sourceDeleted,
                                              NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

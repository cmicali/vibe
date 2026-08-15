//
//  MainPlayerController+Convert.h
//  Vibe
//
//  Convert to FLAC's controller half: the funnel both menu items share, the
//  playlist swap that puts the FLAC into its source's rows, and the undo
//  round trip. The engine — encode, sandbox rungs, tag copy, disposal
//  primitives — is AudioFileConverter, in Audio/Convert/.
//

#import "MainPlayerController.h"

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Convert)

// Convert > Convert to FLAC, acting on the current track; the window body's
// context-menu item shares it. Declared here, as the Transport actions are,
// so the compiler checks the implementation in this file.
- (IBAction)convertCurrentTrackToFLAC:(nullable id)sender;

// Edit > Undo and Redo, forwarding to the window's NSUndoManager. Convert to
// FLAC registers the only undoable action; the round trip moves files through
// the Trash and never re-encodes.
- (IBAction)undo:(nullable id)sender;
- (IBAction)redo:(nullable id)sender;

// YES from the moment NSUndoManager invokes a conversion inverse until its
// final file move settles. The menu and debug channel use the same gate as the
// actions, so an asynchronous inverse cannot be re-entered.
@property (nonatomic, readonly, getter=isConversionUndoRedoInFlight)
        BOOL conversionUndoRedoInFlight;

// Convert > Delete Original, the checkmarked preference, persisted in
// AppSettings; a running conversion keeps the value it was accepted with.
- (IBAction)toggleDeleteOriginalAfterConvert:(nullable id)sender;

// The shared terminus of both Convert to FLAC menu items, swap included. The
// completion runs after the swap *and* the disposal settle, reporting what
// the disposal actually did — the convert_to_flac verb answers for the
// original without racing the Trash. The menu items pass nil.
- (void)convertTrackToFLAC:(AudioTrack *)track
                completion:(void (^_Nullable)(NSURL *_Nullable outputURL,
                                              BOOL sourceDeleted,
                                              NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

//
//  AudioFileConverter.h
//  Vibe
//
//  Convert to FLAC: the encode, the tag carry-over and getting the result past
//  the sandbox into the folder the source came from.
//

#import <Foundation/Foundation.h>

#import "FLACDisposalRules.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
@class NSWindow;
@class NSMenuItem;

extern NSString *const kVibeConvertErrorDomain;

typedef NS_ENUM(NSInteger, VibeConvertErrorCode) {
    VibeConvertErrorBusy = 1,
    VibeConvertErrorNotConvertible,
    VibeConvertErrorDestinationExists,
    VibeConvertErrorRestoreFailed,
    VibeConvertErrorEncodeFailed,
    VibeConvertErrorTagCopyFailed,
    VibeConvertErrorTrashFailed,
    VibeConvertErrorReplacementUnavailable,
    VibeConvertErrorDestinationMatchesSource,
};

@interface AudioFileConverter : NSObject

// Main thread. YES from accept until the completion runs; menu validation
// disables on it — concurrent encodes would race for one destination name.
@property (readonly, getter=isConverting) BOOL converting;

// Encode progress, on the main thread at about one-percent steps, with the
// track so the owner can tell whether it is the one on screen.
@property (copy, nullable) void (^progressHandler)(AudioTrack *track, double fraction);

// Encodes track's file to the FLAC beside it — foo.wav becomes foo.flac —
// copies the tags across and moves it into place. Asynchronous; completion
// runs on the main thread with the URL actually written, which differs from
// the sibling path when the sandbox forced a save panel. Never overwrites the
// automatic sibling destination; a save-panel replacement happens only after
// the panel confirms it and may never name the source itself. window hosts the
// panel; nil makes a denied sibling write fail. A dismissed panel reports
// NSUserCancelledError.
- (void)convertTrackToFLAC:(AudioTrack *)track
          presentingWindow:(nullable NSWindow *)window
                completion:(void (^)(NSURL *_Nullable outputURL, NSError *_Nullable error))completion;

// Stops the running conversion at its next buffer: the temporary FLAC is
// removed and the request completes with NSUserCancelledError, the same
// decision-not-failure a dismissed save panel reports. A conversion already
// past its encode — copying tags, placing the file, or waiting on the panel —
// runs to its own completion instead. Main thread. completion runs on the
// main thread once that request has completed, or asynchronously at once when
// none is running; Quit parks its reply here so the temp file is gone before
// the process exits.
- (void)cancelConversionWithCompletion:(nullable void (^)(void))completion;

// Trashes the file a finished conversion consumed, when Convert > Delete
// Original was on at accept — a toggle flipped mid-encode applies to the next
// conversion, never the one in flight. Trash rather than unlink, so it is
// undoable. Call on the main thread once the FLAC has taken the source's
// place; the player holds the source open until then. Failure is non-fatal
// and only logged. completion always runs asynchronously on the main thread.
// Its outcome says whether the file moved independently of the optional URL;
// a successful Trash move is allowed to have no location the caller can use
// for restoration.
- (void)trashSourceIfEnabled:(NSURL *)sourceURL
                 convertedTo:(NSURL *)outputURL
                  completion:(nullable void (^)(VibeTrashOutcome outcome,
                                                NSURL *_Nullable trashedURL,
                                                NSError *_Nullable error))completion;

// The undo/redo file primitives for Undo Convert to FLAC. Main thread; the
// moves run on a serial queue — unbounded on a cloud or network folder — and
// the completions on main. Both are coordinated writes: a FLAC only the
// related-item rung could place is writable only through the presenter's file
// coordination. The restore refuses to overwrite, so something new at the
// original path is never clobbered.
- (void)trashItemAtURL:(NSURL *)url
            completion:(void (^)(VibeTrashOutcome outcome,
                                 NSURL *_Nullable trashedURL,
                                 NSError *_Nullable error))completion;
- (void)restoreTrashedItemAtURL:(NSURL *)trashedURL
                          toURL:(NSURL *)originalURL
                     completion:(void (^)(BOOL restored, NSError *_Nullable error))completion;

// Positively verifies that a replacement can be read and parsed as audio
// before undo, redo or conversion lets it take a playlist row and disposes of
// the currently playable counterpart. Main thread; the probe runs on the
// serial disposal queue and completion returns asynchronously on main.
- (void)verifyPlayableFileAtURL:(NSURL *)url
                     completion:(void (^)(BOOL playable, NSError *_Nullable error))completion;

// The FLAC that would sit beside sourceURL; the conversion and the menu rule
// share it, so the item talks about the file the action writes.
+ (NSURL *)flacDestinationForURL:(NSURL *)sourceURL;

// Warms the cached "does this track's FLAC already exist" answer that menu
// validation reads, statting off the main thread. Call it whenever the track
// the menus name changes, and after a conversion. Main thread; nil clears.
- (void)refreshDestinationStateForTrack:(nullable AudioTrack *)track;

// The enable-and-retitle rule for an idle Convert to FLAC item, in one place
// so the menus that carry one cannot drift. Returns what the caller's
// validateMenuItem: should return. The running case is the controller's — the
// item becomes Cancel Conversion — so this is never asked while converting.
- (BOOL)validateConvertMenuItem:(NSMenuItem *)menuItem forTrack:(nullable AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END

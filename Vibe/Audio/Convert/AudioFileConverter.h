//
//  AudioFileConverter.h
//  Vibe
//
//  Convert to FLAC: the encode, the tag carry-over and getting the result past
//  the sandbox into the folder the source came from.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
@class NSWindow;
@class NSMenuItem;

extern NSString *const kVibeConvertErrorDomain;

typedef NS_ENUM(NSInteger, VibeConvertErrorCode) {
    VibeConvertErrorBusy = 1,
    VibeConvertErrorNotConvertible,
    VibeConvertErrorDestinationExists,
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
// destination. window hosts the panel; nil makes a denied sibling write fail.
// A dismissed panel reports NSUserCancelledError.
- (void)convertTrackToFLAC:(AudioTrack *)track
          presentingWindow:(nullable NSWindow *)window
                completion:(void (^)(NSURL *_Nullable outputURL, NSError *_Nullable error))completion;

// Trashes the file a finished conversion consumed, when Convert > Delete
// Original was on at accept — a toggle flipped mid-encode applies to the next
// conversion, never the one in flight. Trash rather than unlink, so it is
// undoable. Call on the main thread once the FLAC has taken the source's
// place; the player holds the source open until then. Failure is non-fatal
// and only logged. completion always runs asynchronously on the main thread
// with where the Trash put the file — nil when nothing moved — for the
// caller's undo record.
- (void)trashSourceIfEnabled:(NSURL *)sourceURL
                 convertedTo:(NSURL *)outputURL
                  completion:(nullable void (^)(NSURL *_Nullable trashedURL))completion;

// The undo/redo file primitives for Undo Convert to FLAC. Main thread; the
// moves run on a serial queue — unbounded on a cloud or network folder — and
// the completions on main. Both are coordinated writes: a FLAC only the
// related-item rung could place is writable only through the presenter's file
// coordination. The restore refuses to overwrite, so something new at the
// original path is never clobbered.
- (void)trashItemAtURL:(NSURL *)url
            completion:(void (^)(NSURL *_Nullable trashedURL, NSError *_Nullable error))completion;
- (void)restoreTrashedItemAtURL:(NSURL *)trashedURL
                          toURL:(NSURL *)originalURL
                     completion:(void (^)(BOOL restored, NSError *_Nullable error))completion;

// The FLAC that would sit beside sourceURL; the conversion and the menu rule
// share it, so the item talks about the file the action writes.
+ (NSURL *)flacDestinationForURL:(NSURL *)sourceURL;

// Warms the cached "does this track's FLAC already exist" answer that menu
// validation reads, statting off the main thread. Call it whenever the track
// the menus name changes, and after a conversion. Main thread; nil clears.
- (void)refreshDestinationStateForTrack:(nullable AudioTrack *)track;

// The whole enable-and-retitle rule for a Convert to FLAC item, in one place
// so the menus that carry one cannot drift. Returns what the caller's
// validateMenuItem: should return.
- (BOOL)validateConvertMenuItem:(NSMenuItem *)menuItem forTrack:(nullable AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END

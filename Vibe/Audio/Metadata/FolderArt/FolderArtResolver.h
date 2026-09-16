//
// FolderArtResolver.h
// Vibe
//
// The album-art fallback for files that carry none of their own: a cover image
// sitting beside the audio file — cover.jpg, folder.jpg, front.jpg, album.jpg.
// AudioTrackArtwork consults it, so every art consumer sees the result through
// the ordinary art accessors.
//
// Nobody asks for this feature, so it rides along with what the player already
// does rather than paying its own way:
//
//  - Per *directory*, never per track: one album folder costs one resolve
//    however many tracks it holds, and they share the images.
//  - It never pays for a listing of its own. Opening anything but a single file
//    already walks the directories, so the cover comes out of that walk for
//    free (noteListedDirectories:…), and a bulk open of loose files marks its
//    folders for one listing each (preferListingForDirectories:). Only a lone
//    file probes, and then just the three commonest spellings.
//  - Asked and answered: a folder with no cover, no grant, or an unreadable or
//    undecodable one stays settled in a bounded recent-directory history.
//  - Settling a folder records a path and opens nothing. The file is read and
//    decoded only when a track carrying no art of its own needs pixels, so a
//    fully tagged library never opens a cover.
//  - Never on the metadata scan's path — the accessors resolve, lazily, for the
//    tracks actually on screen.
//  - Never persisted. The metadata cache is keyed by the audio file's size and
//    mtime, which a sidecar image cannot move, so a cached cover would outlive
//    its file by up to the cache's age limit.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread when a folder's artwork question has been answered,
// so the playlist and the header can redraw. **"It has none" is an answer and
// is posted too**: the header keeps the previous track's art up while the
// answer is pending, and would otherwise leave it there.
extern NSNotificationName const FolderArtDidResolveNotification;

@interface FolderArtResolver : NSObject

+ (instancetype)sharedInstance;

// The playlist-cell thumbnail for this file's folder, or nil while unknown or
// when the folder has no cover. **Never blocks, never touches the file system,
// and costs O(1) under the lock**, so cells may call it while drawing:
// resolveIfUnknown schedules the resolve in the background instead, and
// FolderArtDidResolveNotification reports the result. Any thread.
- (nullable VibeImage *)cachedThumbnailForAudioFilePath:(nullable NSString *)path
                                       resolveIfUnknown:(BOOL)resolveIfUnknown;

// The full-resolution cover, if it is decoded right now. Same non-blocking
// contract as the thumbnail, for the main thread's updateUI pass.
- (nullable VibeImage *)cachedDisplayImageForAudioFilePath:(nullable NSString *)path;

// The full-resolution cover, resolving the folder and decoding it if needed.
// Blocking — stats, a file read and a decode — so background threads only.
- (nullable VibeImage *)displayImageForAudioFilePath:(nullable NSString *)path;

// YES when a background load would produce something the non-blocking
// accessors cannot: the folder is unresolved, or its cover is not decoded right
// now. Goes NO for good once a folder is known to have none, so
// AudioTrackArtwork.artNeedsLoad cannot spin. A pure read — it runs on the
// main thread's updateUI pass.
- (BOOL)needsBackgroundLoadForAudioFilePath:(nullable NSString *)path;

// The caller was walking these directories anyway and reports what was in them:
// every directory visited, and the cover found in the ones that have one. Each
// settles without a syscall of our own — the path a folder drop or open takes.
// Recorded whether or not the setting is on, so switching it on later gets this
// answer rather than the lone file's guesswork.
- (void)noteListedDirectories:(nullable NSSet<NSString *> *)directories
       artFilenameByDirectory:(nullable NSDictionary<NSString *, NSString *> *)artFilenameByDirectory;

// These folders came from opening more than one file at once, where the extra
// I/O is already the order of the day: resolve them with one listing each
// rather than the lone file's stat probes. Lazy — the listing happens if and
// when something asks for their art — and a fact about how the user opened
// them rather than a cached answer, so the setting changing leaves it alone.
- (void)preferListingForDirectories:(nullable NSSet<NSString *> *)directories;

// The album-art setting changed. **Every path that writes it must call this**,
// since the value is cached here. Releases the decoded covers, worth some 20MB
// and useless while the setting is off.
//
// **The settled answers deliberately survive**: the setting governs whether the
// fallback is consulted, never what a folder contains. Forgetting them would
// throw away the covers a folder walk harvested for free and leave those
// folders to the stat probes, which know three of the candidate names — so a
// toggle off and on would lose the art for every other spelling.
- (void)folderArtSettingDidChange;

// Reconsiders only access-dependent answers: folders left unresolved for want
// of a grant, and known cover paths whose reads were paused after a scope ended.
// The latter keep their donated path and recheck access before the next read. A
// full invalidate here is actively harmful: opening a folder auto-adds its grant
// milliseconds later, so wiping everything discards the covers that same open's
// walk harvested for free.
- (void)invalidateDirectoriesSettledWithoutGrant;

@end

NS_ASSUME_NONNULL_END

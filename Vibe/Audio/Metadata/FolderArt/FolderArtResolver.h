//
// FolderArtResolver.h
// Vibe
//
// The cover beside an audio file that carries no art of its own, consulted by
// AudioTrackArtwork. Per directory, lazy, never on the scan's path and never
// persisted; the cost rules are FolderArt/CLAUDE.md's.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Posted on main when a folder's question is answered, "it has none"
// included: the header holds the previous track's art until the answer.
extern NSNotificationName const FolderArtDidResolveNotification;

@interface FolderArtResolver : NSObject

+ (instancetype)sharedInstance;

// The row thumbnail, or nil. Never blocks or touches the filesystem, O(1)
// under the lock, so safe while drawing; resolveIfUnknown schedules a
// background resolve. Any thread.
- (nullable VibeImage *)cachedThumbnailForAudioFilePath:(nullable NSString *)path
                                       resolveIfUnknown:(BOOL)resolveIfUnknown;

// The full cover if decoded now; non-blocking.
- (nullable VibeImage *)cachedDisplayImageForAudioFilePath:(nullable NSString *)path;

// Resolves, reads and decodes as needed. Blocking: background only.
- (nullable VibeImage *)displayImageForAudioFilePath:(nullable NSString *)path;

// YES while the folder is unresolved or its cover undecoded; NO for good once
// it has none, so artNeedsLoad cannot spin. A pure read, on main.
- (BOOL)needsBackgroundLoadForAudioFilePath:(nullable NSString *)path;

// A walk's harvest: every directory visited and the cover in each that has
// one, settled with no I/O of ours. Recorded even with the setting off.
- (void)noteListedDirectories:(nullable NSSet<NSString *> *)directories
       artFilenameByDirectory:(nullable NSDictionary<NSString *, NSString *> *)artFilenameByDirectory;

// Folders from a multi-file open: resolve each, lazily, by one listing rather
// than stat probes.
- (void)preferListingForDirectories:(nullable NSSet<NSString *> *)directories;

// Every writer of the setting must reach this: the value is cached here.
// Drops decoded covers and keeps every settled answer, since the setting
// governs whether the fallback is consulted, not what a folder holds.
- (void)folderArtSettingDidChange;

// Forgets no-grant answers and re-arms read-blocked covers, which keep their
// path. Never a full wipe: an open's grant lands just after its walk.
- (void)invalidateDirectoriesSettledWithoutGrant;

@end

NS_ASSUME_NONNULL_END

//
//  FolderWalkInternal.h
//  Vibe
//
//  Synchronous expansion steps for FolderWalk.m, its tests and the bench harness.
//

#import "FolderWalk.h"

NS_ASSUME_NONNULL_BEGIN

@class PlaylistEntry;

@interface FolderWalk (Internal)

// The nonempty audio anywhere under dir as entries; Name sorts by full path,
// grouping subfolders.
+ (NSArray<PlaylistEntry *> *)expandDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort;

// The already-sorted listing, with sheets standing in for their audio files.
+ (NSArray<PlaylistEntry *> *)entriesForWalk:(NSArray<NSURL *> *)urls;

// Folders and top-level playlist files expanded in place, every entry
// playable. looseFileDirectories collects the folders of files not found by
// walking a folder; expandedCount, the entries before unplayable ones were
// dropped.
+ (NSArray<PlaylistEntry *> *)expandFileList:(NSArray<NSURL *> *)list
                                    sortedBy:(VibeFolderOpenSort)sort
                                 folderCount:(nullable NSUInteger *)folderCount
                        looseFileDirectories:(nullable NSMutableSet<NSString *> *)looseFileDirectories
                               expandedCount:(nullable NSUInteger *)expandedCount;

+ (NSArray<PlaylistEntry *> *)expandAndFilterList:(NSArray<NSURL *> *)list
                                         sortedBy:(VibeFolderOpenSort)sort
                                      folderCount:(nullable NSUInteger *)folderCount;

@end

NS_ASSUME_NONNULL_END

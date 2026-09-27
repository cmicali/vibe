//
//  NSURLUtilInternal.h
//  Vibe
//
//  The synchronous expansion steps, for the unit tests. Nothing but
//  NSURLUtil.m and its tests imports it.
//

#import "NSURLUtil.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSURLUtil (Internal)

// The audio anywhere under dir; Name sorts by full path, grouping subfolders.
+ (NSArray<NSURL *> *)expandDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort;

// Folders and top-level playlist files expanded in place; other URLs pass
// through unfiltered. looseFileDirectories collects the folders of files not
// found by walking a folder.
+ (NSArray<NSURL *> *)expandFileList:(NSArray<NSURL *> *)list
                            sortedBy:(VibeFolderOpenSort)sort
                         folderCount:(nullable NSUInteger *)folderCount
                looseFileDirectories:(nullable NSMutableSet<NSString *> *)looseFileDirectories;

+ (NSArray<NSURL *> *)expandAndFilterList:(NSArray<NSURL *> *)list
                                 sortedBy:(VibeFolderOpenSort)sort
                              folderCount:(nullable NSUInteger *)folderCount;

@end

NS_ASSUME_NONNULL_END

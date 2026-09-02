//
//  NSURLUtilInternal.h
//  Vibe
//
//  The expansion steps behind expandAndFilterList:sortedBy:completion:, exposed so the
//  unit tests can drive one walk synchronously — through the async form alone
//  the four-wide queue and the main-thread hop stand between every assertion
//  and what the walk actually yielded. Do not import it outside NSURLUtil.m
//  and its tests; the app funnels through NSURLUtil.h.
//

#import "NSURLUtil.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSURLUtil (Internal)

// One folder walk: the audio files anywhere under dir, in sort's order — by
// full path for Name, so subfolders group.
+ (NSArray<NSURL *> *)expandDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort;

// Folders and top-level playlist files expanded in place, every other URL
// passed through in the order given and unfiltered. folderCount, when not
// NULL, counts the directories among the top-level URLs. looseFileDirectories
// collects the folders of files that did NOT come from walking a folder — a
// multi-file open, or a playlist file's tracks.
+ (NSArray<NSURL *> *)expandFileList:(NSArray<NSURL *> *)list
                            sortedBy:(VibeFolderOpenSort)sort
                         folderCount:(nullable NSUInteger *)folderCount
                looseFileDirectories:(nullable NSMutableSet<NSString *> *)looseFileDirectories;

// The body of the async form: expandFileList: plus the extension filter.
+ (NSArray<NSURL *> *)expandAndFilterList:(NSArray<NSURL *> *)list
                                 sortedBy:(VibeFolderOpenSort)sort
                              folderCount:(nullable NSUInteger *)folderCount;

@end

NS_ASSUME_NONNULL_END

//
//  FileSearchIndexInternal.h
//  Vibe (iOS)
//
//  Test seams. Do not import it outside FileSearchIndex.m and its tests.
//

#import "FileSearchIndex.h"

NS_ASSUME_NONNULL_BEGIN

@interface FileSearchIndex (Internal)

// Every root covered by another removed, either direction; no disk access.
+ (NSArray<NSURL *> *)pruneNestedRoots:(NSArray<NSURL *> *)roots;

// For proving a repeated query scans only newly appended rows. The count is
// kept only in debug builds.
- (void)appendFileURLForTesting:(NSURL *)url;
@property (nonatomic, readonly) NSUInteger lastFilterEvaluationCountForTesting;

// A cap below kMaxIndexedFiles, set before beginBuildIfNeeded, and the token
// of the walk that fills the index, so a test sees the cap cancel it.
@property (nonatomic) NSUInteger maxIndexedFilesForTesting;
@property (nonatomic, readonly, nullable) NSProgress *buildProgressForTesting;

@end

NS_ASSUME_NONNULL_END

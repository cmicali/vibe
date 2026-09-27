//
//  FileSearchIndex.h
//  Vibe (iOS)
//
//  The search screen's files section: every audio file under the roots
//  PlaybackController.searchRoots composes, walked once into memory and
//  filtered off main per keystroke. The walk STREAMS, and reads directory
//  listings only — never bytes or tags — so a provider tree costs no downloads.
//
//  Main thread only; the walk and the filter have private queues.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FileSearchIndex;

// Named entirely from its path.
@interface FileSearchHit : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *url;
// Extension included.
@property (nonatomic, readonly) NSString *fileName;
// The row's second line, matched alongside the filename.
@property (nonatomic, readonly) NSString *folderName;
@end

@protocol FileSearchIndexDelegate <NSObject>
// On main, only between beginBuildIfNeeded and the walk finishing.
- (void)fileSearchIndexDidGrow:(FileSearchIndex *)index;
- (void)fileSearchIndexDidFinishBuilding:(FileSearchIndex *)index;
@end

@interface FileSearchIndex : NSObject

@property (nonatomic, weak) id<FileSearchIndexDelegate> delegate;

// So the screen can say it is still looking.
@property (nonatomic, readonly) BOOL isBuilding;

// The same roots are a no-op; any change discards the index and abandons a
// walk in flight.
- (void)setRoots:(NSArray<NSURL *> *)roots;

// Cheap to call on every appearance of the search screen, the only caller:
// nothing walks a provider tree before the user asks to search.
- (void)beginBuildIfNeeded;

// Matching runs off main; an unchanged query over a growing index examines
// only the appended suffix. Discovery order, capped at limit. excludedPaths is
// keyed by NSURL.path. An empty query matches nothing. Only the latest request
// delivers, on main.
- (void)requestHitsMatchingQuery:(NSString *)query
                       excluding:(nullable NSSet<NSString *> *)excludedPaths
                           limit:(NSUInteger)limit
                      completion:(void (^)(NSArray<FileSearchHit *> *hits))completion;

// Supersedes pending localized filtering without discarding the index.
- (void)cancelPendingHitRequests;

@end

NS_ASSUME_NONNULL_END

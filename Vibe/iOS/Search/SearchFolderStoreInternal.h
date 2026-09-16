//
//  SearchFolderStoreInternal.h
//  Vibe (iOS)
//
//  The retained security-scope grant handed from search to FolderSession.
//  SearchFolderStore keeps removed entries alive until every such grant ends.
//  Do not import this outside SearchFolderStore.m and FolderSession.m.
//

#import "SearchFolderStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface SearchFolderGrant : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *rootURL;

@end

@interface SearchFolderStore (Internal)

// Retains the live persistent grant whose root covers url. nil means the URL
// is covered only by FolderSession's transient root or the app container.
- (nullable SearchFolderGrant *)grantCoveringURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END

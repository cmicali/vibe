//
//  SearchFolderStoreInternal.h
//  Vibe (iOS)
//
//  The grant FolderSession retains; a removed entry's scope stops only when
//  every grant ends. Only SearchFolderStore.m and FolderSession.m import it.
//

#import "SearchFolderStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface SearchFolderGrant : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *rootURL;

@end

@interface SearchFolderStore (Internal)

// Nil when only a transient root or the app container covers url.
- (nullable SearchFolderGrant *)grantCoveringURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END

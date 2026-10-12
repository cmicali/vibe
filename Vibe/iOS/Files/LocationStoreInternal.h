//
//  LocationStoreInternal.h
//  Vibe (iOS)
//
//  The grant FolderSession retains; a removed entry's scope stops only when
//  every grant ends. FolderSession holds grants across opens and playback.
//

#import "LocationStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface LocationGrant : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *rootURL;

@end

@interface LocationStore (Internal)

// Nil when only a transient root or the app container covers url.
- (nullable LocationGrant *)grantCoveringURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END

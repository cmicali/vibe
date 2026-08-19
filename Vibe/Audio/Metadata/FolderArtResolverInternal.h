//
//  FolderArtResolverInternal.h
//  Vibe
//
//  Deterministic I/O seams and diagnostics for focused resolver tests.
//

#import "FolderArtResolver.h"

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^FolderArtEnabledProvider)(void);
typedef BOOL (^FolderArtAccessProvider)(NSString *directory);
typedef NSArray<NSString *> * _Nullable (^FolderArtDirectoryLister)(NSString *directory);
typedef BOOL (^FolderArtFileInfoProvider)(NSString *path,
                                          unsigned long long * _Nullable size);
typedef NSData * _Nullable (^FolderArtDataReader)(NSString *path);
typedef VibeImage * _Nullable (^FolderArtDecoder)(NSData *data, CGFloat maxPixelSize);

@interface FolderArtResolver (Internal)

- (instancetype)initWithEnabledProvider:(FolderArtEnabledProvider)enabledProvider
                         accessProvider:(FolderArtAccessProvider)accessProvider
                                 lister:(FolderArtDirectoryLister)lister
                               fileInfo:(FolderArtFileInfoProvider)fileInfo
                             dataReader:(FolderArtDataReader)dataReader
                                decoder:(FolderArtDecoder)decoder;

- (instancetype)initWithEnabledProvider:(FolderArtEnabledProvider)enabledProvider
                         accessProvider:(FolderArtAccessProvider)accessProvider;

@property (nonatomic, readonly) NSUInteger recordedDirectoryCount;

- (nullable NSString *)settledArtPathForDirectory:(nullable NSString *)directory;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

//
//  FilesViewController.h
//  Vibe (iOS)
//
//  The Files tab. A pick opens through FolderSession, as the picker's does.
//  A browser, not an embedded picker: the picker is not supported as a child.
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface FilesViewController : UIDocumentBrowserViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initForOpeningFilesWithContentTypes:
        (nullable NSArray<NSString *> *)allowedContentTypes NS_UNAVAILABLE;
- (instancetype)initForOpeningContentTypes:
        (nullable NSArray<UTType *> *)contentTypes NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

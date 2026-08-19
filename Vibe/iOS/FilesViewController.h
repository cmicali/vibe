//
//  FilesViewController.h
//  Vibe (iOS)
//
//  The Files tab: the system's own file browser, over the same providers the
//  document picker reaches (On My iPhone, iCloud Drive, Dropbox — anything
//  with a Files extension). Picking audio opens it exactly as the picker does,
//  through FolderSession, so a file still expands to its directory when a
//  grant covers it and the directory-as-playlist model is unchanged.
//
//  It is UIDocumentBrowserViewController rather than an embedded
//  UIDocumentPickerViewController: the picker is a modal presentation and is
//  not supported as a child, while the browser is built to be a root.
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

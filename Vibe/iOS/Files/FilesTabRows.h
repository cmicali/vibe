//
//  FilesTabRows.h
//  Vibe (iOS)
//
//  Vibe's groups below the browser's Locations, which PlaybackBrowserHost
//  hands the root (rootSections): Recents, then Choose File…, Open URL…, and
//  the paste row while the clipboard probably holds a web link. It holds the
//  link flow, the paste row's clipboard check, and Choose File…'s picker.
//

#import <UIKit/UIKit.h>

#import "VibeBrowserHost.h"

@class PlaybackBrowserHost;
@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface FilesTabRows : NSObject

// The host opens what Choose File… picks, and redraws a section whose rows
// changed.
- (instancetype)initWithPlayback:(PlaybackController *)playback
                       appending:(BOOL)appending
                            host:(PlaybackBrowserHost *)host NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSArray<NSArray<VibeBrowserRootRow *> *> *)sections;
// Checks the clipboard for the paste row.
- (void)rootWillAppear:(UIViewController *)root;

// Open URL…'s sheet, and the paste row's items, over screen. The debug
// channel drives both.
- (void)presentLinkSheetFromScreen:(UIViewController *)screen;
- (void)pasteItemProviders:(NSArray<NSItemProvider *> *)itemProviders fromScreen:(UIViewController *)screen;

@end

NS_ASSUME_NONNULL_END

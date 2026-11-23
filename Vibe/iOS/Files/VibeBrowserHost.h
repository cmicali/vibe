//
//  VibeBrowserHost.h
//  Vibe (iOS)
//
//  The browser's folder screens as the app sees them. A folder screen names
//  no model class of the app's. It reads what its rows show from a host, and
//  every row and selection action is a value the host supplies: its title,
//  its glyph, and what it does with the rows. So one app offers Play and Add
//  to Playlist, and another offers Import. Its words, its sort setting, and
//  the holders its art loads into are the host's too.
//
//  Main thread only.
//

#import <UIKit/UIKit.h>

#import "FolderOpenSort.h"

@protocol AudioTrackMetadataHolder;
@protocol EqualizerLevelSource;

NS_ASSUME_NONNULL_BEGIN

// One action on rows. The handler gets the rows' URLs, in row order, and the
// screen they were on, which the app may present from.
@interface VibeBrowserAction : NSObject

+ (instancetype)actionWithTitle:(NSString *)title
                         symbol:(NSString *)symbol
                        handler:(void (^)(NSArray<NSURL *> *urls, UIViewController *screen))handler;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *title;
// An SF Symbol's name.
@property (nonatomic, readonly, copy) NSString *symbol;
@property (nonatomic, readonly, copy) void (^handler)(NSArray<NSURL *> *urls, UIViewController *screen);
// The rows go to the screen's addedRowsHandler before the handler runs.
@property (nonatomic) BOOL liftsRows;

@end

// The browser's fixed words. Counted ones are methods of the host.
typedef NS_ENUM(NSInteger, VibeBrowserLabel) {
    VibeBrowserLabelSelect,           // the Select button's VoiceOver label
    VibeBrowserLabelSelectAll,
    VibeBrowserLabelSort,             // the sort button's VoiceOver label
    VibeBrowserLabelSortMenuTitle,
    VibeBrowserLabelFilter,           // the filter field's placeholder
    VibeBrowserLabelEmptyFolder,      // a folder with nothing to show or play
    VibeBrowserLabelUnavailable,      // a listing that could not be refreshed
    VibeBrowserLabelOK,
};

// What changed in the host. Each screen redraws what it shows.
@protocol VibeBrowserHostObserver <NSObject>
- (void)browserHostPlayingFileDidChange;
- (void)browserHostPlayStateDidChange;
- (void)browserHostOpeningDidChange;
@end

@protocol VibeBrowserHost <NSObject>

#pragma mark What the rows show

// Comparable paths (VibeComparablePath). The playing file's row carries the
// equalizer, and the row being opened spins.
@property (nonatomic, readonly, copy, nullable) NSString *playingPath;
@property (nonatomic, readonly, copy, nullable) NSString *openingPath;
// Whether audio is coming out, and what the equalizer reads its levels from.
@property (nonatomic, readonly) BOOL audioOutputActive;
@property (nonatomic, readonly, nullable) id<EqualizerLevelSource> levelSource;
// Held weakly.
- (void)addObserver:(id<VibeBrowserHostObserver>)observer;

#pragma mark How the screens look and read

- (NSString *)label:(VibeBrowserLabel)label;
// The title while selecting, and the alert for a subfolder walk that stopped
// at its limit.
- (NSString *)selectionTitleForCount:(NSUInteger)count;
- (NSString *)subfoldersCappedMessageForLimit:(NSUInteger)limit;
// Over every screen's title, or nil for none.
@property (nonatomic, readonly, copy, nullable) NSString *prompt;
// Close at every level, for a stack presented as a sheet.
@property (nonatomic, readonly) BOOL showsCloseButton;
// The sort menu in the bar, which writes folderSort.
@property (nonatomic, readonly) BOOL showsSortMenu;
// The order every listing and walk uses. The sort menu writes it.
@property (nonatomic) VibeFolderOpenSort folderSort;
- (NSString *)titleForSort:(VibeFolderOpenSort)sort;
// The holder a file row's album art loads into, through the stack's metadata
// cache.
- (id<AudioTrackMetadataHolder>)artHolderForFileURL:(NSURL *)url;

#pragma mark The actions

// A file row's tap, a second one on a spinning row included. A folder row's
// tap opens the folder.
- (void)screen:(UIViewController *)screen didTapFile:(NSURL *)url;
// Select's bar button and a row's swipe. Its rows are lifted when it says so.
@property (nonatomic, readonly) VibeBrowserAction *selectionAction;
// The bar button, on the folder shown.
@property (nonatomic, readonly) VibeBrowserAction *folderAction;
// The bar button's menu item: the folder shown with its subfolders. The host
// is asked when the user picks it, before the walk lists anything. The
// browser hands the folders with songs, in walk order, to the block returned.
@property (nonatomic, readonly) NSString *subfoldersTitle;
- (void (^)(NSArray<NSURL *> *folders))subfoldersHandlerFromScreen:(UIViewController *)screen;
// A row's long press. Asked each time the menu opens.
- (NSArray<VibeBrowserAction *> *)menuActionsForURL:(NSURL *)url isFolder:(BOOL)isFolder;

@end

NS_ASSUME_NONNULL_END

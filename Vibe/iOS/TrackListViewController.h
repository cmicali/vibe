//
//  TrackListViewController.h
//  Vibe (iOS)
//
//  The playlist button's sheet: the current directory's tracks, with the
//  playing row marked, plus a Choose Folder row that reopens the picker. It
//  holds the Playlist weakly and renders it; the owner forwards observer
//  changes through the reload methods while the sheet is up.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class Playlist;

@interface TrackListViewController : UITableViewController

- (instancetype)initWithPlaylist:(Playlist *)playlist;

@property (nonatomic, copy, nullable) NSString *folderName;
@property (nonatomic, copy, nullable) void (^onSelectTrack)(NSUInteger index);
@property (nonatomic, copy, nullable) void (^onChooseFolder)(void);

- (void)reloadAll;
- (void)reloadTrackAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END

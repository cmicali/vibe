//
//  FolderViewControllerInternal.h
//  Vibe (iOS)
//
//  The private surface FolderViewController.m and its +Art and +Actions
//  categories share: the screen's state and the methods each side calls on
//  the other. No other file imports it.
//

#import "FolderViewController.h"
#import "AccountMirror.h"
#import "AudioTrackMetadataCache.h"
#import "PlaybackController.h"

typedef NS_ENUM(NSInteger, VibeBrowserSection) {
    VibeBrowserSectionFolders = 0,
    VibeBrowserSectionFiles,
    VibeBrowserSectionCount,
};

@interface FolderViewController () <UISearchResultsUpdating, PlaybackObserver> {
    PlaybackController *_playback;
    NSURL *_directoryURL;
    BOOL _appending;

    // A directory's whole listing, in the folder-open order. Which of the
    // files are an account's placeholders, and each file's size, are found
    // with the listing, off main. The M3U playlists lead the files, and a folder
    // holding nothing else has no song for the play button to play.
    NSArray<NSURL *> *_allFolders;
    NSArray<NSURL *> *_allFiles;
    BOOL _hasSongs;
    NSSet<NSURL *> *_placeholders;
    NSDictionary<NSURL *, NSString *> *_fileSizes;
    // The directory's standardized path, so a row's is one append away.
    NSString *_standardizedPath;
    NSString *_title;
    // The playing file's standardized path, for the row that carries the
    // equalizer.
    NSString *_playingPath;
    // Between viewWillAppear: and viewWillDisappear:, for the equalizer; the
    // stack's exposure is equalizerSurfaceVisible.
    BOOL _viewPresentationVisible;
    // The rows drawn: the listing narrowed by the filter field.
    NSArray<NSURL *> *_folders;
    NSArray<NSURL *> *_files;
    // Stamped on each disk listing, so a slow one cannot overwrite a newer.
    uint64_t _listingGeneration;
    // The account mirror this directory lies in, nil outside every mirror:
    // listed from disk at once, then refreshed from the service.
    AccountMirror *_mirror;
    BOOL _refreshing;
    NSError *_refreshError;
    // When this screen last listed its folder from its account; a
    // reappearance within kRelistInterval shows the disk alone.
    CFAbsoluteTime _listedAt;
    // Open Folder's file, shown and briefly selected once the listing lands.
    NSURL *_highlightURL;
    // Open Folder on a folder no persistent root covers (a one-off pick in
    // Recents): this screen holds its scope, and the subfolders pushed above
    // it read under it. The session's hold may be gone with the playlist.
    BOOL _holdsScope;

    // Album art through the app's own metadata pipeline: the stack's one
    // cache (stackArtCache), and a track per row that has been near the
    // screen. Every song may show art the cache already holds; only the
    // local ones may be parsed for it.
    AudioTrackMetadataCache *(^_stackArtCache)(void);
    AudioTrackMetadataCache *_artCache;
    NSSet<NSURL *> *_songFiles;
    NSSet<NSURL *> *_localFiles;
    // The not-local songs already looked up, so a miss is asked once per
    // listing.
    NSMutableSet<NSURL *> *_cacheOnlyAsked;
    NSMutableDictionary<NSURL *, AudioTrack *> *_artTracks;

    // A row swipe sets isEditing too; only the Select button's is multi-select.
    BOOL _swipingRow;
    // A subfolder walk is out; a second ask waits for it.
    BOOL _walkingSubfolders;
    UIBarButtonItem *_playItem;
    UIBarButtonItem *_addSelectedItem;
    UIBarButtonItem *_sortItem;
    UIBarButtonItem *_selectItem;
    UIBarButtonItem *_doneItem;
    UIBarButtonItem *_selectAllItem;
    UIBarButtonItem *_closeItem;
    UISearchController *_filter;
}

- (void)reloadFromDisk;
- (BOOL)isEmpty;
- (NSURL *)itemAtIndexPath:(NSIndexPath *)indexPath;
- (void)openDirectory;
- (void)addURLs:(NSArray<NSURL *> *)urls;
- (void)openURLs:(NSArray<NSURL *> *)urls inFolder:(BOOL)inFolder;
- (void)liftRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths;
- (void)pushDirectory:(NSURL *)url;
- (void)favoriteFolder:(NSURL *)url;

@end

// A file row's album art, through the stack's one metadata cache.
@interface FolderViewController (Art) <AudioTrackMetadataCacheDelegate>

- (void)loadArtForVisibleRows;
- (void)artThumbnailDidLoad:(NSNotification *)notification;

@end

// The bar, Select, a row's tap, and its swipe and long press.
@interface FolderViewController (Actions)

- (BOOL)isSelecting;
- (void)refreshBarItems;
- (UIMenu *)sortMenu;
- (void)toggleSelecting;
- (void)selectAllRows;

@end

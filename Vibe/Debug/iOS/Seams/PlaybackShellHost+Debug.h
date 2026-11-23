//
//  PlaybackShellHost+Debug.h
//  Vibe (iOS)
//
//  The host adopts VibeDebugPlayerSurface because it is the one object that
//  sees the whole app. It forwards player and playlist reads to its
//  PlaybackController, pager reads to its card, and tab and card state to its
//  root. The iOS twin of Mac/Seams/MainPlayerController+DebugPlayerSurface.h.
//

#if DEBUG

#import "RootViewController.h"
#import "PlaybackShellHost.h"
#import "DebugPlayerSurface.h"
#import "VibeBrowserRootViewController.h"   // the categories below need the classes
#import "FilesTabRows.h"
#import "FavoritesViewController.h"
#import "PlaylistViewController.h"
#import "SearchViewController.h"
#import "OutputRouteRules.h"        // VibeOutputRouteKind, taken below
#import "OpenURLSheetController+Debug.h"

@class AudioTrackMetadataCache;
@class AudioWaveformCache;
@class FavoriteFolder;
@class PlaybackController;
@class PlayerViewController;

// Declaration-only access to production methods in PlaybackShellHost.m and
// PlaybackShellHost+AddedRows.m.
@interface PlaybackShellHost (DebugSurface)

@property (nonatomic, readonly) PlayerViewController *player;
// Each is nil until its tab's lazy provider has run.
@property (nonatomic, readonly) PlaylistViewController *playlistScreen;
@property (nonatomic, readonly) FavoritesViewController *favorites;
@property (nonatomic, readonly) SearchViewController *searchScreen;
@property (nonatomic, readonly) VibeBrowserRootViewController *filesBrowser;
// Unsettled row lifts, oldest first, in CACurrentMediaTime units.
@property (nonatomic, readonly) NSArray<NSNumber *> *liftedRowTimes;

@end

@interface PlaybackShellHost (DebugLayout)
- (NSDictionary *)debugLayoutAnchors;
// Every display-link frame, for `seconds`; dump_layout_samples reads them.
- (void)debugBeginLayoutSamplingForSeconds:(NSTimeInterval)seconds;
- (NSDictionary *)debugLayoutSamples;
@end

@interface PlaylistViewController (DebugSurface)
- (void)favoriteTapped;
@end

@interface FilesTabRows (Debug)
// {pasteRowShown, pasteRowResolving, linkSheet: {shown, text, resolving,
// openEnabled}}.
- (NSDictionary *)debugLinkState;
// Open URL's sheet while it is up, else nil.
- (OpenURLSheetController *)debugLinkSheet;
@end

@interface FavoritesViewController (DebugSurface)
- (void)openFavorite:(FavoriteFolder *)favorite appending:(BOOL)appending;
@end

@interface SearchViewController (DebugSurface)
// Puts the query in the FIELD and filters: currentQuery is read from the
// field, and the files half's delivery is dropped if the two disagree.
- (void)setQueryText:(NSString *)query;
// So a poll can tell "no matches" from "not finished looking".
- (BOOL)isBuildingFileIndex;
// Gates both the walk and the file matching. NO means the files half never ran
// (the card is up, another tab is forward, or the scene is inactive), which
// otherwise looks like a query that matched no file.
- (BOOL)isMateriallyVisible;
@end

@interface PlaybackShellHost (Debug) <VibeDebugPlayerSurface>

// The selected tab, with the search tab named "search": its own identifier
// is UIKit's.
@property (nonatomic, copy) NSString *debugSelectedTabName;

- (NSDictionary *)debugStateDictionary;
// The pager's art window and each page's art state: on screen, "not decoded
// yet" and "no art" are both the placeholder.
- (NSDictionary *)debugArtDictionary;
- (NSDictionary *)debugActionSummary;
- (void)debugPlayPause;
- (void)debugNext;
- (void)debugPlayIndex:(NSUInteger)index;
- (void)debugPrevious;
// Through the scrubber's didSeek path, so the seek-in-flight guard behaves as
// on a real drag's release.
- (void)debugSeekToSeconds:(NSTimeInterval)seconds;
- (void)debugSetWaveformZoom:(CGFloat)fraction;
// Exactly what tapping the star does; the ADD lands asynchronously because the
// bookmark is minted off main. NO when there is no Playlist tab yet or no open
// folder.
- (BOOL)debugTapFavoriteStar;
// What a favorite row's tap (or, appending, its Add) does. Indexes the
// store's list, as dump_favorites does; the screen's copy can lag a
// notification turn. NO when the Favorites tab was never visited or the index
// is past the list.
- (BOOL)debugOpenFavoriteAtIndex:(NSUInteger)index appending:(BOOL)appending;
// Reports both sections after stable row counts or a six-second poll limit.
// NO when the Search tab was never visited.
- (BOOL)debugSearchQuery:(NSString *)query
              completion:(void (^)(NSDictionary *result))completion;
// Taps a files-section row, which OPENS it.
- (BOOL)debugTapSearchFileAtIndex:(NSUInteger)index;

// Draws the card's route indicator as `kind`, model untouched: the simulator
// never reports an off-device route.
- (void)debugSetOutputRouteKind:(VibeOutputRouteKind)kind deviceName:(NSString *)name;
- (void)debugOpenPath:(NSString *)path;
- (void)debugAppendPath:(NSString *)path;
- (void)debugOpenLink:(NSString *)link completion:(void (^)(NSURL *file, NSError *error))completion;
// The root browser Open URL acts on: the add sheet's while it is up, else
// the Files tab's. nil until the Files tab was visited.
- (VibeBrowserRootViewController *)debugActiveBrowser;
// The active browser's Vibe groups.
- (FilesTabRows *)debugActiveTabRows;
- (AudioTrackMetadataCache *)debugMetadataCache;
- (AudioWaveformCache *)debugWaveformCache;

@end

#endif

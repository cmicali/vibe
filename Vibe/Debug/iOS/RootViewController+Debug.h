//
//  RootViewController+Debug.h
//  Vibe (iOS)
//
//  The shell adopts VibeDebugPlayerSurface because it is the one object that
//  sees the whole app: it forwards player and playlist reads to its
//  PlaybackController and pager reads to its card. The iOS twin of
//  Mac/Introspection/MainPlayerController+DebugPlayerSurface.h.
//

#if DEBUG

#import "RootViewController.h"
#import "DebugPlayerSurface.h"
#import "FavoritesViewController.h" // the categories below need the classes
#import "LibraryViewController.h"
#import "SearchViewController.h"
#import "OutputRouteRules.h"        // VibeOutputRouteKind, taken below

@class AudioTrackMetadataCache;
@class AudioWaveformCache;
@class FavoriteFolder;
@class PlaybackController;
@class PlayerViewController;

// Declaration-only access to production methods in RootViewController.m.
@interface RootViewController (DebugSurface)

@property (nonatomic, readonly) PlaybackController *playback;
@property (nonatomic, readonly) PlayerViewController *player;
// Each is nil until its tab's lazy provider has run.
@property (nonatomic, readonly) LibraryViewController *library;
@property (nonatomic, readonly) FavoritesViewController *favorites;
@property (nonatomic, readonly) SearchViewController *searchScreen;
@property (nonatomic, readonly, getter=isPlayerExpanded) BOOL playerExpanded;
@property (nonatomic, readonly, getter=isMiniPlayerShown) BOOL miniPlayerShown;
@property (nonatomic, copy) NSString *selectedTabIdentifier;
// Seconds since each Add's rows were lifted and not yet settled, oldest
// first; one past a few seconds is an Add that never came back.
@property (nonatomic, readonly) NSArray<NSNumber *> *liftedRowAges;
// The live tabs (the view controller and its view), the strip, and what
// moves over them: the backdrop snapshot's scale (1 with none up) and the
// card's offset from fully up. For the layout probe.
@property (nonatomic, readonly) UITabBarController *tabs;
@property (nonatomic, readonly) UIView *miniPlayerView;
@property (nonatomic, readonly) CGFloat backdropScale;
@property (nonatomic, readonly) CGFloat cardOffset;

- (void)expandPlayerAnimated:(BOOL)animated;
- (void)minimizePlayerAnimated:(BOOL)animated;

@end

@interface RootViewController (DebugLayout)
- (NSDictionary *)debugLayoutAnchors;
- (void)debugBeginLayoutSamplingForSeconds:(NSTimeInterval)seconds hertz:(NSInteger)hertz;
- (NSDictionary *)debugLayoutSamples;
// seconds of 0 runs until replaced; logging reports every five seconds, the
// device's road, since --log-stderr is all a phone offers.
- (void)debugBeginFrameProbeForSeconds:(NSTimeInterval)seconds logging:(BOOL)logging;
- (NSDictionary *)debugFrameProbeReport;
@end

@interface LibraryViewController (DebugSurface)
- (void)favoriteTapped;
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

@interface RootViewController (Debug) <VibeDebugPlayerSurface>

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
// Reports both sections as drawn, once the table settles (the files half is
// asynchronous). NO when the Search tab was never visited.
- (BOOL)debugSearchQuery:(NSString *)query
              completion:(void (^)(NSDictionary *result))completion;
// Taps a files-section row, which OPENS it.
- (BOOL)debugTapSearchFileAtIndex:(NSUInteger)index;

// Draws the card's route indicator as `kind`, model untouched: the simulator
// never reports an off-device route.
- (void)debugSetOutputRouteKind:(VibeOutputRouteKind)kind deviceName:(NSString *)name;
- (void)debugOpenPath:(NSString *)path;
- (void)debugAppendPath:(NSString *)path;
- (AudioTrackMetadataCache *)debugMetadataCache;
- (AudioWaveformCache *)debugWaveformCache;

@end

#endif

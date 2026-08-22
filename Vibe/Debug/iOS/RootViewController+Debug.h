//
//  RootViewController+Debug.h
//  Vibe (iOS)
//
//  Extra surface for the debug command channel (Vibe/Debug/iOS/DebugCommands.m),
//  the iOS twin of Introspection/MainPlayerController+Debug.h. The shell is
//  what adopts VibeDebugPlayerSurface, because it is the one object that can
//  see the whole app: it forwards the player and playlist reads to its
//  PlaybackController and the pager reads to its card.
//
//  It lives here, with its implementation beside it, so the shipping header
//  carries no conditional about a tool that does not ship. Debug builds only.
//

#if DEBUG

#import "RootViewController.h"
#import "DebugPlayerSurface.h"
#import "FavoritesViewController.h" // the categories below need the classes,
#import "LibraryViewController.h"   // not a @class
#import "SearchViewController.h"
#import "OutputRouteRules.h"        // VibeOutputRouteKind, taken below

@class AudioTrackMetadataCache;
@class AudioWaveformCache;
@class PlaybackController;
@class PlayerViewController;

// Declaration-only access to production methods used by the debug adapter.
// Their implementation stays in RootViewController.m; keeping this separate
// avoids putting debug-only surface in the shipping header.
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

- (void)expandPlayerAnimated:(BOOL)animated;
- (void)minimizePlayerAnimated:(BOOL)animated;

@end

// The star lives on the Playlist tab's navigation bar, and the channel cannot
// synthesize the tap — the same reason expand_player and select_tab exist.
@interface LibraryViewController (DebugSurface)
- (void)favoriteTapped;
@end

// The search field takes KEYSTROKES, which the channel cannot synthesize and
// the touch driver has no verb for either — so a query, and the row tap that
// follows it, come through here.
@interface SearchViewController (DebugSurface)
// Puts the query in the FIELD and filters — the field is where currentQuery is
// read from, and the file half's delivery is dropped if the two disagree.
- (void)setQueryText:(NSString *)query;
// Whether the file walk is still running, so a poll can tell "no matches" from
// "not finished looking".
- (BOOL)isBuildingFileIndex;
// The walk and the file matching are BOTH gated on this. False means the files
// half answered nothing because it never ran — the card is up over this screen,
// another tab is forward, or the scene is not active — which is otherwise
// indistinguishable from a query that genuinely matched no file.
- (BOOL)isMateriallyVisible;
@end

@interface RootViewController (Debug) <VibeDebugPlayerSurface>

- (NSDictionary *)debugStateDictionary;
// The pager's art window and each page's art state. Nothing on screen tells
// "not decoded yet" from "no art at all" — both are the placeholder — so this
// is the only way to see whether the prefetch is keeping up.
- (NSDictionary *)debugArtDictionary;
// The compact reply the transport verbs share.
- (NSDictionary *)debugActionSummary;
- (void)debugPlayPause;
- (void)debugNext;
- (void)debugPlayIndex:(NSUInteger)index;
- (void)debugPrevious;
// Routes through the scrubber's didSeek path so the seek-in-flight guard
// behaves exactly as a real drag's release.
- (void)debugSeekToSeconds:(NSTimeInterval)seconds;
// The waveform zoom, the one gesture the command channel cannot synthesize.
- (void)debugSetWaveformZoom:(CGFloat)fraction;
// Exactly what tapping the star does: it toggles, and the ADD lands
// asynchronously because the bookmark has to be minted off main. Returns NO
// when there is no Playlist tab yet or no open folder to star.
- (BOOL)debugTapFavoriteStar;
// Exactly what tapping a favorite row does, resolve and alert included. NO
// means the Favorites tab was never visited, or the index is past the list.
- (BOOL)debugTapFavoriteAtIndex:(NSUInteger)index;
// Runs a query through the search screen and reports both sections as it draws
// them. The files half is asynchronous, so this settles on the table rather
// than on the keystroke; NO means the Search tab was never visited.
- (BOOL)debugSearchQuery:(NSString *)query
              completion:(void (^)(NSDictionary *result))completion;
// Taps a row of the search screen's files section — an OPEN, where a playlist
// row would be a mere selection.
- (BOOL)debugTapSearchFileAtIndex:(NSUInteger)index;

// Draws the card's route indicator as a given route, model untouched — the
// only way to see the off-device renderings, which the simulator never reports.
- (void)debugSetOutputRouteKind:(VibeOutputRouteKind)kind deviceName:(NSString *)name;
- (void)debugOpenPath:(NSString *)path;
- (AudioTrackMetadataCache *)debugMetadataCache;
- (AudioWaveformCache *)debugWaveformCache;

@end

#endif

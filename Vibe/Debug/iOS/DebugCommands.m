//
//  DebugCommands.m
//  Vibe (iOS)
//

#import "DebugCommands.h"

#if DEBUG

#import <UIKit/UIKit.h>
#import "DebugChannel.h"
#import "DebugWireFormat.h"
#import "DebugCommandDispatch.h"
#import "DebugCommonVerbs.h"
#import "FavoritesStore.h"
#import "AppSettings.h"
#import "PlaybackController.h"
#import "PlayerDisplaySettings.h"
#import "RootViewController.h"
#import "RootViewController+Debug.h"
#import "SearchFolderStore.h"
#import "WaveformRendererRegistry.h"

static UIWindow *VibeDebugKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

// The shell adopts VibeDebugPlayerSurface: the one object that reaches both
// the model and the card.
static RootViewController *VibeDebugRootController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *root = window.rootViewController;
            if ([root isKindOfClass:RootViewController.class]) {
                return (RootViewController *)root;
            }
        }
    }
    return nil;
}

#pragma mark View tree and screenshot

static NSDictionary *VibeViewDictionary(UIView *view) {
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"class"] = NSStringFromClass(view.class);
    node[@"frame"] = NSStringFromCGRect(view.frame);
    if (view.isHidden) {
        node[@"hidden"] = @YES;
    }
    if (view.alpha < 1.0) {
        node[@"alpha"] = @(view.alpha);
    }
    if ([view isKindOfClass:UILabel.class]) {
        node[@"text"] = ((UILabel *)view).text ?: @"";
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSString *label = button.currentTitle ?: button.accessibilityLabel;
        if (label.length) {
            node[@"label"] = label;
        }
    }
    if (view.subviews.count) {
        NSMutableArray *subviews = [NSMutableArray array];
        for (UIView *subview in view.subviews) {
            [subviews addObject:VibeViewDictionary(subview)];
        }
        node[@"subviews"] = subviews;
    }
    return node;
}

static NSString *VibeViewTreeDump(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [windows addObject:@{
                @"class": NSStringFromClass(window.class),
                @"frame": NSStringFromCGRect(window.frame),
                @"keyWindow": @(window.isKeyWindow),
                @"rootViewController": NSStringFromClass(window.rootViewController.class) ?: @"",
                @"contentView": VibeViewDictionary(window),
            }];
        }
    }
    return VibeJSONString(@{@"windows": windows});
}

// In-process render of the key window. Blurs render only approximately this
// way; `simctl io booted screenshot` is the ground truth for pixels.
static NSString *VibeScreenshotJSON(NSString *commandId) {
    UIWindow *window = VibeDebugKeyWindow();
    if (!window) {
        return VibeErrorJSON(@"no key window");
    }
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds format:format];
    NSData *png = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }];
    NSString *path = VibeDebugScreenshotPathForCommand(commandId);
    if (![png writeToFile:path atomically:YES]) {
        return VibeErrorJSON(@"could not write %@", path);
    }
    return VibeJSONString(@{@"ok": @YES, @"path": path,
                            @"pointWidth": @(window.bounds.size.width),
                            @"pointHeight": @(window.bounds.size.height),
                            @"scale": @(format.scale)});
}

#pragma mark Search scope

// roots: what the search walk covers, composed by the model. folders: the rows
// Settings shows, the only part a user can change.
static NSDictionary *VibeSearchScopeDictionary(RootViewController *controller) {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    for (NSURL *root in controller.playback.searchRoots) {
        [roots addObject:root.path ?: @""];
    }
    SearchFolderStore *store = SearchFolderStore.shared;
    NSMutableArray<NSDictionary *> *folders = [NSMutableArray array];
    NSArray<NSURL *> *urls = store.folderURLs;
    for (NSUInteger i = 0; i < urls.count; i++) {
        [folders addObject:@{@"name": [store displayNameForFolderAtIndex:i],
                             @"path": urls[i].path ?: @""}];
    }
    return @{@"roots": roots, @"folders": folders};
}

static NSDictionary *VibeFavoritesDictionary(void) {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (FavoriteFolder *favorite in FavoritesStore.shared.favorites) {
        [rows addObject:@{@"name": favorite.name,
                          @"location": favorite.location,
                          @"path": favorite.path}];
    }
    return @{@"favorites": rows};
}

#pragma mark Command table

// The iOS-only verbs; shared ones are in DebugCommonVerbs.m.
static NSArray<NSDictionary *> *VibeiOSCommandTable(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            VibeDebugCmd(@"dump_view_tree", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                return VibeViewTreeDump();
            }),
            VibeDebugCmd(@"dump_screenshot", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                return VibeScreenshotJSON(commandId);
            }),
            VibeDebugCmd(@"dump_art", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                return VibeJSONString([controller debugArtDictionary]);
            }),
            // The card presents and dismisses by gesture, which the channel
            // cannot synthesize.
            VibeDebugCmd(@"expand_player", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                [controller expandPlayerAnimated:NO];
                return VibeJSONString([controller debugActionSummary]);
            }),
            VibeDebugCmd(@"minimize_player", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                [controller minimizePlayerAnimated:NO];
                return VibeJSONString([controller debugActionSummary]);
            }),
            // Stands in for the pinch. Both numbers come back because they may
            // differ: the request is persisted, the drawn zoom is clamped to
            // what this layout's bitmap can hold.
            VibeDebugCmd(@"set_waveform_zoom <fraction>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                double fraction = 0;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &fraction)) {
                    return VibeErrorJSON(@"usage: set_waveform_zoom <fraction 0-1>");
                }
                [controller debugSetWaveformZoom:fraction];
                NSDictionary *ui = [controller debugStateDictionary][@"ui"];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"waveformZoomRequested": ui[@"waveformZoomRequested"] ?: @0,
                    @"waveformZoomEffective": ui[@"waveformZoomEffective"] ?: @0,
                });
            }),
            // Ends on the same two lines as the Settings picker's onSelect: a
            // write without the notification persists and redraws nothing.
            // Takes the persisted identifier, never the localized name, and
            // refuses an unknown one, since the renderer's fallback would make
            // a typo look like a style.
            //
            // TRAP: the wiggle identifiers read backwards: `wiggle` is displayed
            // "Wiggle MC" and `wiggle_centered` "Wiggle". Both draw wiggles, so
            // asking for the wrong one looks like it worked.
            VibeDebugCmd(@"set_waveform_style <identifier>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                NSArray<NSString *> *available = [WaveformRendererRegistry availableIdentifiers];
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: set_waveform_style <%@>",
                                         [available componentsJoinedByString:@"|"]);
                }
                if (![available containsObject:tokens[1]]) {
                    return VibeErrorJSON(@"unknown waveform style '%@'; available: %@",
                                         tokens[1], [available componentsJoinedByString:@", "]);
                }
                AppSettings.sharedInstance.waveformStyle = tokens[1];
                VibeNotifyDisplaySettingsChanged();
                return VibeJSONString(@{@"ok": @YES, @"waveformStyle": AppSettings.sharedInstance.waveformStyle});
            }),
            // The real grant path is the system document picker, another
            // process's UI that neither the channel nor the touch driver can
            // drive; these three inspect and set up the scope for a test.
            //
            // TRAP: a folder added here is NOT security-scoped, so it survives
            // only the session. A test that relaunches must add it again.
            VibeDebugCmd(@"dump_search", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                return VibeJSONString(VibeSearchScopeDictionary(controller));
            }),
            VibeDebugCmd(@"add_search_folder <path>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: add_search_folder <path>");
                }
                NSURL *url = [NSURL fileURLWithPath:tokens[1] isDirectory:YES];
                // added:NO is the "already covered" answer, not a failure.
                BOOL added = [SearchFolderStore.shared addFolderURL:url];
                NSMutableDictionary *reply =
                        [VibeSearchScopeDictionary(controller) mutableCopy];
                reply[@"ok"] = @YES;
                reply[@"added"] = @(added);
                return VibeJSONString(reply);
            }),
            VibeDebugCmd(@"remove_search_folder <index>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                NSInteger index = tokens.count > 1 ? tokens[1].integerValue : -1;
                if (index < 0 || (NSUInteger)index >= SearchFolderStore.shared.folderURLs.count) {
                    return VibeErrorJSON(@"usage: remove_search_folder <index in dump_search.folders>");
                }
                [SearchFolderStore.shared removeFolderAtIndex:(NSUInteger)index];
                NSMutableDictionary *reply =
                        [VibeSearchScopeDictionary(controller) mutableCopy];
                reply[@"ok"] = @YES;
                return VibeJSONString(reply);
            }),
            // The simulator reports only the built-in speaker and a route
            // cannot be faked at the session, so this draws the indicator
            // alone; the next real route event overwrites it.
            VibeDebugCmd(@"set_output_route <none|speaker|receiver|wired|bluetooth|airplay|carplay|other> [name]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                NSDictionary<NSString *, NSNumber *> *kinds = @{
                    @"none": @(VibeOutputRouteKindNone),
                    @"speaker": @(VibeOutputRouteKindBuiltInSpeaker),
                    @"receiver": @(VibeOutputRouteKindBuiltInReceiver),
                    @"wired": @(VibeOutputRouteKindWired),
                    @"bluetooth": @(VibeOutputRouteKindBluetooth),
                    @"airplay": @(VibeOutputRouteKindAirPlay),
                    @"carplay": @(VibeOutputRouteKindCarPlay),
                    @"other": @(VibeOutputRouteKindOther),
                };
                NSNumber *kind = tokens.count > 1 ? kinds[tokens[1]] : nil;
                if (!kind) {
                    return VibeErrorJSON(@"usage: set_output_route <none|speaker|receiver|wired|bluetooth|airplay|carplay|other> [name]");
                }
                // The name is everything after the kind, rejoined, since an
                // unquoted device name is several tokens.
                NSArray<NSString *> *nameTokens = tokens.count > 2
                        ? [@[tokens[0]] arrayByAddingObjectsFromArray:
                                [tokens subarrayWithRange:NSMakeRange(2, tokens.count - 2)]]
                        : @[];
                NSString *name = nameTokens.count > 0 ? VibeRestArgument(nameTokens) : nil;
                [controller debugSetOutputRouteKind:(VibeOutputRouteKind)kind.unsignedIntegerValue
                                         deviceName:name];
                NSDictionary *ui = [controller debugStateDictionary][@"ui"];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"routeSymbol": ui[@"routeSymbol"] ?: @"",
                    @"routeNameShown": ui[@"routeNameShown"] ?: @NO,
                    @"routeShown": ui[@"routeShown"] ?: @NO,
                });
            }),
            VibeDebugCmd(@"dump_favorites", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                return VibeJSONString(VibeFavoritesDictionary());
            }),
            // Drives the star's real handler. There is deliberately no
            // add-a-path verb: it would record a bookmark with no security
            // scope, a row that draws and cannot be opened.
            //
            // TRAP: the add is asynchronous (the bookmark is minted off main).
            // ok:true means the handler ran, not that the row exists; poll
            // dump_favorites.
            VibeDebugCmd(@"tap_favorite_star", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                if (![controller debugTapFavoriteStar]) {
                    return VibeErrorJSON(@"no open folder on the playlist tab to star");
                }
                return VibeJSONString(@{@"ok": @YES});
            }),
            // Stands in for the row tap through the screen's own
            // openFavorite:appending:, so the resolve, the open and the
            // unreachable-folder alert are the tap's. The Favorites tab must
            // have been selected once: its provider is lazy.
            VibeDebugCmd(@"open_favorite <index in dump_favorites.favorites>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                NSInteger index = tokens.count > 1 ? tokens[1].integerValue : -1;
                if (index < 0) {
                    return VibeErrorJSON(@"usage: open_favorite <index in dump_favorites.favorites>");
                }
                if (![controller debugOpenFavoriteAtIndex:(NSUInteger)index appending:NO]) {
                    return VibeErrorJSON(@"no such favorite row (select_tab favorites first)");
                }
                return VibeJSONString(@{@"ok": @YES});
            }),
            // open_favorite's row, appended instead of opened.
            VibeDebugCmd(@"append_favorite <index in dump_favorites.favorites>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                NSInteger index = tokens.count > 1 ? tokens[1].integerValue : -1;
                if (index < 0) {
                    return VibeErrorJSON(@"usage: append_favorite <index in dump_favorites.favorites>");
                }
                if (![controller debugOpenFavoriteAtIndex:(NSUInteger)index appending:YES]) {
                    return VibeErrorJSON(@"no such favorite row (select_tab favorites first)");
                }
                return VibeJSONString(@{@"ok": @YES});
            }),
            // Keystrokes neither the channel nor the touch driver can
            // synthesize. Both verbs go through the screen's own methods, so
            // the matching and the open are a real search's. `search` replies
            // when the table settles, since the files half answers off a walk.
            VibeDebugCmd(@"search <query>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                NSString *query = tokens.count > 1 ? tokens[1] : @"";
                BOOL started = [controller debugSearchQuery:query
                                                 completion:^(NSDictionary *result) {
                    VibeWriteDebugResponse(commandId, VibeJSONString(result));
                }];
                if (!started) {
                    return VibeErrorJSON(@"the search tab was never visited (select_tab search first)");
                }
                return nil;
            }),
            VibeDebugCmd(@"open_search_hit <index into search.sections[1].rows>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                NSInteger index = tokens.count > 1 ? tokens[1].integerValue : -1;
                if (index < 0 || ![controller debugTapSearchFileAtIndex:(NSUInteger)index]) {
                    return VibeErrorJSON(@"no such file hit (run `search <query>` first)");
                }
                return VibeJSONString(@{@"ok": @YES});
            }),
            VibeDebugCmd(@"select_tab <playlist|favorites|files|search>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                NSString *identifier = tokens.count > 1 ? tokens[1] : nil;
                if (![@[@"playlist", @"favorites", @"files", @"search"] containsObject:identifier ?: @""]) {
                    return VibeErrorJSON(@"usage: select_tab <playlist|favorites|files|search>");
                }
                controller.selectedTabIdentifier = identifier;
                return VibeJSONString(@{@"ok": @YES, @"selectedTab": controller.selectedTabIdentifier});
            }),
        ];
    });
    return table;
}

static NSString *VibeiOSExecuteDebugCommand(NSArray<NSString *> *tokens, NSString *commandId) {
    NSString *verb = tokens.firstObject ?: @"";
    RootViewController *controller = VibeDebugRootController();
    if (!controller) {
        return VibeErrorJSON(@"app not fully launched");
    }
    NSDictionary *spec = VibeDebugSpecForVerb(VibeDebugCommonCommandTable(), verb)
            ?: VibeDebugSpecForVerb(VibeiOSCommandTable(), verb);
    if (!spec) {
        return VibeDebugUnknownCommandReply(verb,
                @[VibeDebugCommonCommandTable(), VibeiOSCommandTable()], nil);
    }
    return ((VibeDebugCommandHandler)spec[@"handler"])(tokens, commandId, controller);
}

void VibeiOSInstallDebugCommandHook(void) {
    VibeInstallDebugCommandChannel(^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return VibeiOSExecuteDebugCommand(args, commandId);
    });
}

#endif

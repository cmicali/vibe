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
#import "PlaybackController.h"
#import "RootViewController.h"
#import "RootViewController+Debug.h"
#import "SearchFolderStore.h"

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

// The shell, which is what adopts VibeDebugPlayerSurface: it is the one object
// that can reach both the model and the card.
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

// In-process render of the key window's hierarchy. UIVisualEffectView blurs
// render only approximately this way; `simctl io booted screenshot` is the
// ground truth for real pixels, and this path is for a device or for reading
// alongside dump_view_tree.
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

// The whole search scope and the user's half of it. The roots are what the
// search screen's walk will cover, composed by the model; the folders are the
// rows Settings shows, which is the only part a user can change.
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

// The UIKit-only verbs. Everything both platforms answer the same way is in
// Debug/DebugCommonVerbs.m, over VibeDebugPlayerSurface; this table is
// only what needs a UIView tree or a UIWindow render.
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
            // The card presents and dismisses by gesture, and the channel
            // cannot synthesize a touch; these are how it is driven without
            // the XCUITest driver.
            VibeDebugCmd(@"expand_player", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                [controller expandPlayerAnimated:NO];
                return VibeJSONString([controller debugActionSummary]);
            }),
            VibeDebugCmd(@"minimize_player", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                [controller minimizePlayerAnimated:NO];
                return VibeJSONString([controller debugActionSummary]);
            }),
            // The zoom pinch is the other gesture the channel cannot
            // synthesize. Both numbers come back because they are allowed to
            // differ: what is asked for is persisted, what is drawn is clamped
            // to what this layout's settled bitmap can hold.
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
            // The search-folder list is granted through the system document
            // picker, which the channel cannot drive at all — not even with the
            // touch driver, since the picker is another process's UI. These three
            // are how the scope is inspected and set up for a test; the real
            // grant path is Settings, and only it can raise the picker.
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
            // The simulator reports the built-in speaker and nothing else,
            // and a route cannot be faked at the session — so this draws the
            // indicator as a route for a look, leaving the model alone. The
            // next real route event overwrites it.
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
                // tokens[0] is the verb and tokens[1] the kind, so the name is
                // whatever follows — rejoined, since an unquoted device name is
                // several tokens.
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
            // The star sits on the Playlist tab's navigation bar and the channel
            // cannot synthesize the tap — the same reason expand_player and
            // select_tab exist. It drives the real handler, so the toggle, the
            // dedupe and the off-main bookmark mint are all the ones the tap
            // gets; there is deliberately no add-a-path verb, which would have
            // to record a bookmark with no security scope behind it and so a
            // row that draws and cannot be opened.
            //
            // TRAP: the ADD is asynchronous. ok:true means the handler ran, not
            // that the row exists — poll dump_favorites for that.
            VibeDebugCmd(@"tap_favorite_star", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                if (![controller debugTapFavoriteStar]) {
                    return VibeErrorJSON(@"no open folder on the playlist tab to star");
                }
                return VibeJSONString(@{@"ok": @YES});
            }),
            // Same reason as the star: the row is a touch the channel cannot
            // make. It drives the screen's own didSelectRow:, so the resolve,
            // the open and the unreachable-folder alert are the tap's.
            // Requires the Favorites tab to have been selected once — the
            // provider is lazy, so before that there is no screen to tap.
            VibeDebugCmd(@"open_favorite <index in dump_favorites.favorites>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                NSInteger index = tokens.count > 1 ? tokens[1].integerValue : -1;
                if (index < 0) {
                    return VibeErrorJSON(@"usage: open_favorite <index in dump_favorites.favorites>");
                }
                if (![controller debugTapFavoriteAtIndex:(NSUInteger)index]) {
                    return VibeErrorJSON(@"no such favorite row (select_tab favorites first)");
                }
                return VibeJSONString(@{@"ok": @YES});
            }),
            // The search field takes keystrokes, which neither the channel nor
            // the touch driver can synthesize. These two are how a query and
            // the row tap that follows it are driven; both go through the
            // screen's own methods, so the matching, the exclusion set and the
            // open are the ones a real search gets. `search` replies when the
            // table settles, since the files half answers off a walk.
            VibeDebugCmd(@"search <query>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                NSString *query = tokens.count > 1 ? tokens[1] : @"";
                BOOL started = [controller debugSearchQuery:query
                                                 completion:^(NSDictionary *result) {
                    VibeWriteDebugResponse(commandId, VibeJSONString(result));
                }];
                if (!started) {
                    return VibeErrorJSON(@"the search tab was never visited (select_tab search first)");
                }
                return nil;   // replies asynchronously
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

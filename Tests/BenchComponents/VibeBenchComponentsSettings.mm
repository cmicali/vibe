//
//  VibeBenchComponentsSettings.mm
//  VibeBenchComponents
//
//  The Settings window offscreen, with no player: what a drag on a theme or
//  level control costs per tick, what a pane refresh costs (every regained
//  key and every closed menu runs one), and what the sidebar search costs per
//  keystroke. The window is never shown, so these measure the panes' own
//  work, not AppKit's display.
//

#import "VibeBenchComponents.h"

#import <AppKit/AppKit.h>

#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AppTheme.h"
#import "SettingsAppearanceViewController.h"
#import "SettingsPaneViewController.h"
#import "SettingsWindowController.h"

struct VibeBenchComponentsSettingsState {
    SettingsWindowController *controller = nil;
    SettingsAppearanceViewController *appearance = nil;
    NSString *themeIdentifier = nil;
};

// A clean store: no themes left from an earlier run, then `count` of its own
// built from the built-ins' records, the last active, so an edit lands in a
// user theme as a real one does.
static NSString *VibeBenchComponentsSettingsUserThemes(NSUInteger count) {
    AppSettings *settings = AppSettings.sharedInstance;
    for (NSString *identifier in settings.orderedThemeIdentifiers) {
        if (![AppTheme isBuiltInIdentifier:identifier]) {
            [settings removeUserThemeWithIdentifier:identifier fallingBackTo:nil];
        }
    }
    NSArray<NSString *> *builtIns = AppTheme.builtInThemeIdentifiers;
    NSString *identifier = nil;
    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *record = [settings recordForThemeIdentifier:builtIns[i % builtIns.count]];
        identifier = [settings addUserThemeWithRecord:record name:[NSString stringWithFormat:@"Bench %lu", (unsigned long)i]];
    }
    [settings applyThemeWithIdentifier:identifier];
    return identifier;
}

static NSString *VibeBenchComponentsSettingsUserTheme(void) {
    return VibeBenchComponentsSettingsUserThemes(1);
}

static void VibeBenchComponentsSettingsEnsureWindow(VibeBenchComponentsSettingsState *state) {
    [NSApplication sharedApplication];
    if (!state->controller) {
        state->controller = [[SettingsWindowController alloc]
                initWithPlayerController:(MainPlayerController *_Nonnull)nil];
        state->appearance = state->controller.appearancePane;
    }
}

static void VibeBenchComponentsRegisterSettings(void) {
    // A color well dragged across sixty ticks over a user theme: each tick
    // writes the color and runs the one persist funnel, as the editor does.
    auto drag = std::make_shared<VibeBenchComponentsSettingsState>();
    VibeBenchComponentsAdd("settings", "theme-color-drag", "tick", [drag]() -> double {
        drag->themeIdentifier = VibeBenchComponentsSettingsUserTheme();
        return 60;
    }, [drag]() {
        AppSettings *settings = AppSettings.sharedInstance;
        for (int i = 0; i < 60; i++) {
            NSColor *color = [NSColor colorWithSRGBRed:i / 60.0 green:0.4 blue:0.6 alpha:1];
            [settings.currentTheme setColor:color forBase:kVibeThemeColorWindowTint dark:YES];
            [settings currentThemeDidChangeContinuous:YES];
        }
    });

    // The same drag with thirty saved themes, a library someone has built up.
    auto library = std::make_shared<VibeBenchComponentsSettingsState>();
    VibeBenchComponentsAdd("settings", "theme-color-drag-30-themes", "tick", [library]() -> double {
        library->themeIdentifier = VibeBenchComponentsSettingsUserThemes(30);
        return 60;
    }, [library]() {
        AppSettings *settings = AppSettings.sharedInstance;
        for (int i = 0; i < 60; i++) {
            NSColor *color = [NSColor colorWithSRGBRed:i / 60.0 green:0.4 blue:0.6 alpha:1];
            [settings.currentTheme setColor:color forBase:kVibeThemeColorWindowTint dark:YES];
            [settings currentThemeDidChangeContinuous:YES];
        }
    });

    // The waveform gain slider dragged across sixty ticks: the setting, the
    // levels effect (no player here) and the preview the pane redraws.
    auto gain = std::make_shared<VibeBenchComponentsSettingsState>();
    VibeBenchComponentsAdd("settings", "waveform-gain-drag", "tick", [gain]() -> double {
        VibeBenchComponentsSettingsEnsureWindow(gain.get());
        return gain->appearance ? 60 : -1;
    }, [gain]() {
        NSSlider *slider = [gain->appearance valueForKey:@"_waveformGainSlider"];
        for (int i = 0; i < 60; i++) {
            slider.doubleValue = -6 + i * 0.2;
            [NSApp sendAction:slider.action to:slider.target from:slider];
        }
    });

    // Every pane but the two that read the player (Audio Output, Advanced),
    // which this tool does not build, refreshed as regaining key or closing a
    // menu refreshes the one selected, the theme editor shown on Appearance.
    auto refresh = std::make_shared<VibeBenchComponentsSettingsState>();
    VibeBenchComponentsAdd("settings", "pane-refresh", "pane", [refresh]() -> double {
        VibeBenchComponentsSettingsEnsureWindow(refresh.get());
        VibeBenchComponentsSettingsUserTheme();
        [refresh->appearance setEditorShown:YES];
        return 6 * 5;
    }, [refresh]() {
        NSTabViewController *tabs = (NSTabViewController *)
                refresh->controller.window.contentViewController.childViewControllers.lastObject;
        for (int i = 0; i < 5; i++) {
            for (NSTabViewItem *item in tabs.tabViewItems) {
                if (![@[@"audio", @"advanced"] containsObject:item.identifier]) {
                    [(SettingsPaneViewController *)item.viewController refreshSettingsAndPaneSize];
                }
            }
        }
    });

    // A pane refreshed with the window on screen (parked off every display),
    // where each refresh remeasures the pane, as regaining key or a menu
    // closing over the window does: Playback, Files, Keyboard Shortcuts, and
    // the theme editor, the largest page.
    for (NSString *pane in @[@"playback", @"files", @"shortcuts", @"appearance/editor"]) {
        auto shown = std::make_shared<VibeBenchComponentsSettingsState>();
        std::string variant = std::string("shown-refresh-") +
                [[pane stringByReplacingOccurrencesOfString:@"/" withString:@"-"] UTF8String];
        VibeBenchComponentsAdd("settings", variant, "refresh", [shown, pane]() -> double {
            VibeBenchComponentsSettingsEnsureWindow(shown.get());
            NSWindow *window = shown->controller.window;
            window.alphaValue = 0;
            [window setFrameOrigin:NSMakePoint(-30000, -30000)];
            [window orderFront:nil];
            NSTabViewController *tabs = (NSTabViewController *)window.contentViewController.childViewControllers.lastObject;
            NSString *identifier = [pane componentsSeparatedByString:@"/"].firstObject;
            for (NSTabViewItem *item in tabs.tabViewItems) {
                if ([item.identifier isEqual:identifier]) {
                    [tabs.tabView selectTabViewItem:item];
                }
            }
            [shown->appearance setEditorShown:[pane hasSuffix:@"/editor"]];
            [window layoutIfNeeded];
            return window.isVisible ? 20 : -1;
        }, [shown]() {
            NSTabViewController *tabs = (NSTabViewController *)
                    shown->controller.window.contentViewController.childViewControllers.lastObject;
            SettingsPaneViewController *selected =
                    (SettingsPaneViewController *)tabs.tabView.selectedTabViewItem.viewController;
            for (int i = 0; i < 20; i++) {
                [selected refreshSettingsAndPaneSize];
            }
        });
    }

    // A query typed a letter at a time and cleared, five times over.
    auto search = std::make_shared<VibeBenchComponentsSettingsState>();
    VibeBenchComponentsAdd("settings", "search-typing", "keystroke", [search]() -> double {
        VibeBenchComponentsSettingsEnsureWindow(search.get());
        return 5 * 12;
    }, [search]() {
        NSString *query = @"bit-perfect";
        for (int i = 0; i < 5; i++) {
            for (NSUInteger length = 1; length <= query.length; length++) {
                [search->controller searchSettingsFor:[query substringToIndex:length]];
            }
            [search->controller searchSettingsFor:@""];
        }
    });
}
VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterSettings)

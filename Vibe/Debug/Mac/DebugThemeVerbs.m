//
//  DebugThemeVerbs.m
//  Vibe
//
//  The theme store and the window appearance.
//

#import "DebugInternal.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AppTheme+Archive.h"
#import "MainPlayerController+Settings.h"
#import "VibeStrings.h"

#if DEBUG

#import "AppTheme.h"

// A theme by stable id or display name (case-insensitive); nil when it names
// nothing.
static NSString *VibeThemeIdentifierMatching(NSString *query) {
    for (NSString *identifier in AppSettings.sharedInstance.orderedThemeIdentifiers) {
        NSString *name = [AppSettings.sharedInstance displayNameForThemeIdentifier:identifier];
        if ([identifier isEqualToString:query] ||
            [name caseInsensitiveCompare:query] == NSOrderedSame) {
            return identifier;
        }
    }
    return nil;
}

NSArray<NSDictionary *> *VibeDebugThemeVerbs(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            VibeDebugCmd(@"set_theme <id-or-name>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: set_theme <id-or-name>");
                }
                NSString *match = VibeThemeIdentifierMatching(tokens[1]);
                if (!match) {
                    return VibeErrorJSON(@"unknown theme: %@", tokens[1]);
                }
                [AppSettings.sharedInstance applyThemeWithIdentifier:match];
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectThemeApply];
                return VibeJSONString(@{@"ok": @YES, @"activeTheme": match});
            }),
            VibeDebugCmd(@"remove_theme <id-or-name>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: remove_theme <id-or-name>");
                }
                NSString *match = VibeThemeIdentifierMatching(tokens[1]);
                if (!match) {
                    return VibeErrorJSON(@"unknown theme: %@", tokens[1]);
                }
                if ([AppTheme isBuiltInIdentifier:match]) {
                    return VibeErrorJSON(@"built-in themes cannot be removed: %@", match);
                }
                // Removing the active theme applies the built-in Vibe theme
                // in the store; the apply effect makes that visible.
                BOOL wasActive = [AppSettings.sharedInstance.activeThemeIdentifier
                        isEqualToString:match];
                [AppSettings.sharedInstance removeUserThemeWithIdentifier:match fallingBackTo:nil];
                if (wasActive) {
                    [controller applySettingsLiveEffects:VibeSettingsLiveEffectThemeApply];
                }
                return VibeJSONString(@{@"ok": @YES, @"removed": match,
                        @"activeTheme": AppSettings.sharedInstance.activeThemeIdentifier,
                        @"themeCount": @(AppSettings.sharedInstance.orderedThemeIdentifiers.count)});
            }),
            // Inline JSON or a path the app can read (the container, or a
            // granted folder).
            VibeDebugCmd(@"import_theme <json|path>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: import_theme <json|path>");
                }
                NSData *data = [tokens[1] hasPrefix:@"{"]
                        ? [tokens[1] dataUsingEncoding:NSUTF8StringEncoding]
                        : [NSData dataWithContentsOfFile:tokens[1]];
                NSString *name = nil;
                NSError *error = nil;
                NSDictionary *record = [AppTheme recordFromJSONOrArchiveData:data
                                                                         name:&name
                                                                        error:&error];
                if (!record) {
                    return VibeErrorJSON(@"not a theme: %@", error.localizedDescription ?: @"unreadable");
                }
                // The same default the Settings pane's import gives a file
                // that carried no name of its own.
                NSString *identifier = [AppSettings.sharedInstance addUserThemeWithRecord:record
                        name:(name.length ? name : STR_THEME_NAME_IMPORTED)];
                return VibeJSONString(@{@"ok": @YES, @"imported": identifier,
                        @"name": [AppSettings.sharedInstance displayNameForThemeIdentifier:identifier],
                        @"themeCount": @(AppSettings.sharedInstance.orderedThemeIdentifiers.count)});
            }),
            VibeDebugCmd(@"dump_theme [id-or-name]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2) {
                    return VibeJSONString(@{@"ok": @YES,
                            @"activeTheme": AppSettings.sharedInstance.activeThemeIdentifier,
                            @"theme": AppSettings.sharedInstance.currentTheme.dictionaryRepresentation});
                }
                NSString *match = VibeThemeIdentifierMatching(tokens[1]);
                if (!match) {
                    return VibeErrorJSON(@"unknown theme: %@", tokens[1]);
                }
                NSData *json = [AppTheme JSONDataForRecord:
                        [AppSettings.sharedInstance recordForThemeIdentifier:match]
                                                      name:[AppSettings.sharedInstance
                                                            displayNameForThemeIdentifier:match]];
                NSDictionary *record = [NSJSONSerialization JSONObjectWithData:json
                                                                       options:0 error:NULL];
                return VibeJSONString(@{@"ok": @YES, @"id": match, @"theme": record});
            }),
            VibeDebugCmd(@"set_appearance <light|dark|system>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSDictionary<NSString *, NSString *> *values = @{
                    @"light": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT,
                    @"dark": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK,
                    @"system": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT,
                };
                // The empty string (system) is a present, non-nil value.
                NSString *value = tokens.count == 2 ? values[tokens[1].lowercaseString] : nil;
                if (!value) {
                    return VibeErrorJSON(@"usage: set_appearance <light|dark|system>");
                }
                AppSettings.sharedInstance.windowAppearanceStyle = value;
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectWindowAppearance];
                return VibeJSONString(@{@"ok": @YES, @"windowAppearance": tokens[1]});
            }),
        ];
    });
    return table;
}

#endif

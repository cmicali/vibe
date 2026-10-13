//
//  AppSettings+Themes.h
//  Vibe
//
//  The theme store: the user themes, the active theme, the working record,
//  its undo history and the image sweep. AppSettings+Mac.h imports it.
//

#import "AppSettings.h"
#import "AppTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface AppSettings (Themes)

// Themed appearance fields have no AppSettings accessors. Read currentTheme.

// The working theme every appearance consumer reads, materialized once and
// mutated in place. Main thread only.
- (AppTheme *)currentTheme;

// The named theme the working state derives from: a built-in identifier or a
// user theme's minted id, snapped to vibe when it names neither.
- (NSString *)activeThemeIdentifier;

// Built-ins first, then the user themes in creation order.
- (NSArray<NSString *> *)orderedThemeIdentifiers;

// A user theme's stored name; the built-ins' localized names. nil for an
// identifier that names nothing.
- (nullable NSString *)displayNameForThemeIdentifier:(NSString *)identifier;

// The named theme's sanitized sparse record; vibe's (empty) for an unknown
// identifier.
- (NSDictionary<NSString *, id> *)recordForThemeIdentifier:(NSString *)identifier;

// Edits, renames and removals share fifty undo/redo entries; continuous edits
// coalesce. Applying a theme clears history. Images stay on disk while history
// can restore them. The caller requests ThemeApply.
@property (readonly, nonatomic) BOOL canUndoThemeEdit;
@property (readonly, nonatomic) BOOL canRedoThemeEdit;
@property (readonly, nonatomic) BOOL themeUndoRemovesTheme;
@property (readonly, nonatomic) BOOL themeRedoRemovesTheme;
@property (readonly, nonatomic) BOOL currentThemeIsModified;
- (void)undoThemeEdit;
- (void)redoThemeEdit;

// Store only: the caller requests VibeSettingsLiveEffectThemeApply.
- (void)applyThemeWithIdentifier:(NSString *)identifier;

// The one persist funnel, called after every currentTheme field edit. The
// working record lands in the active user theme, or for a built-in in the
// divergence key, which re-applying the theme clears. A continuous control
// (a slider, a tracking color well) passes continuous:YES so undo folds the
// gesture into one entry.
- (void)currentThemeDidChange;
- (void)currentThemeDidChangeContinuous:(BOOL)continuous;

// Every mutation refuses a built-in identifier; names are deduped against
// every display name. Duplicating the active theme copies its working record.
// duplicate answers nil for an unknown source. Removing the active theme
// activates the successor (vibe when it names nothing) and the caller requests
// VibeSettingsLiveEffectThemeApply. Each path sweeps orphaned images itself.
- (NSString *)addUserThemeWithRecord:(NSDictionary<NSString *, id> *)record
                                name:(nullable NSString *)name;
- (nullable NSString *)duplicateThemeWithIdentifier:(NSString *)identifier;
- (void)removeUserThemeWithIdentifier:(NSString *)identifier
                        fallingBackTo:(nullable NSString *)successor;
- (void)renameUserThemeWithIdentifier:(NSString *)identifier toName:(NSString *)name;

// NO, with no error and nothing stored, when `identifier` is no longer the
// active user theme. The caller reads `data` off main, since a picked file can
// sit on a share. It then calls currentThemeDidChange and requests the
// field's live effect.
- (BOOL)setCurrentThemeImageForKey:(NSString *)key
                 themeIdentifier:(NSString *)identifier
                            data:(nullable NSData *)data
                           error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END

//
//  MenuShortcutRules.h
//  Vibe
//
//  Vibe's remappable commands and their default shortcuts: the table every
//  ShortcutRules.h decision runs over. Identity is the menu identifier, so a
//  shortcut is the menu item's key equivalent too.
//

#import "ShortcutRules.h"
#import "MenuValidationRules.h"

NS_ASSUME_NONNULL_BEGIN

// Pairs of identifier and default, in the order a hand-edited duplicate
// resolves: the first command wins. Key codes are HIToolbox's kVK_* values,
// inline so Carbon stays unimported.
static inline NSArray<NSArray *> *VibeShortcutTable(void) {
    static NSArray<NSArray *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSEventModifierFlags cmd = NSEventModifierFlagCommand;
        table = @[
            @[kVibeMenuPlay,              @(VibeShortcutMake(49, 0))],   // Space
            @[kVibeMenuPreviousTrack,     @(VibeShortcutMake(11, 0))],   // B
            @[kVibeMenuNextTrack,         @(VibeShortcutMake(45, 0))],   // N
            @[kVibeMenuPlaySelected,      @(VibeShortcutMake(kVibeKeyCodeReturn, 0))],
            @[kVibeMenuShuffle,           @(VibeShortcutMakeCharacter('s', cmd | NSEventModifierFlagOption))],
            @[kVibeMenuRepeat,            @(VibeShortcutMakeCharacter('r', cmd))],
            @[kVibeMenuSkipForward,       @(VibeShortcutMake(0, 0))],    // A
            @[kVibeMenuSkipForwardMore,   @(VibeShortcutMake(1, 0))],    // S
            @[kVibeMenuSkipForwardMost,   @(VibeShortcutMake(2, 0))],    // D
            @[kVibeMenuSkipBack,          @(VibeShortcutMake(6, 0))],    // Z
            @[kVibeMenuSkipBackMore,      @(VibeShortcutMake(7, 0))],    // X
            @[kVibeMenuSkipBackMost,      @(VibeShortcutMake(8, 0))],    // C
            @[kVibeMenuPitchRange8,       @(kVibeShortcutNone)],
            @[kVibeMenuPitchRange16,      @(kVibeShortcutNone)],
            @[kVibeMenuFXLowKill,         @(VibeShortcutMake(12, 0))],   // Q
            @[kVibeMenuFXLowKillBoost,    @(VibeShortcutMake(13, 0))],   // W
            @[kVibeMenuFXReverb,          @(VibeShortcutMake(14, 0))],   // E
            @[kVibeMenuFXDelay,           @(VibeShortcutMake(15, 0))],   // R
            @[kVibeMenuFXShortDelay,      @(VibeShortcutMake(17, 0))],   // T
            @[kVibeMenuShowPlaylist,      @(VibeShortcutMake(48, 0))],   // Tab
            @[kVibeMenuShowPitch,         @(VibeShortcutMake(35, 0))],   // P
            @[VibeWindowSizeMenuIdentifier(VibeWindowSizePresetSmall),   @(kVibeShortcutNone)],
            @[VibeWindowSizeMenuIdentifier(VibeWindowSizePresetDefault), @(kVibeShortcutNone)],
            @[VibeWindowSizeMenuIdentifier(VibeWindowSizePresetLarge),   @(kVibeShortcutNone)],
            @[kVibeMenuAlwaysOnTop,       @(kVibeShortcutNone)],
            @[kVibeMenuLockWindowPosition, @(kVibeShortcutNone)],
            @[kVibeMenuOpen,              @(VibeShortcutMakeCharacter('o', cmd))],
            @[kVibeMenuSavePlaylist,      @(VibeShortcutMakeCharacter('s', cmd))],
            @[kVibeMenuEditCopyName,      @(VibeShortcutMakeCharacter('c', cmd | NSEventModifierFlagShift))],
            @[kVibeMenuEditRemoveFromPlaylist, @(VibeShortcutMake(kVibeKeyCodeDelete, 0))],
            @[kVibeMenuConvertToFLAC,     @(kVibeShortcutNone)],
            @[kVibeMenuConvertDeleteOriginal, @(kVibeShortcutNone)],
            // Last: a default added later loses its key to an override stored
            // before it. A duplicate resolves in table order.
            @[kVibeMenuOpenLink,          @(VibeShortcutMakeCharacter('l', cmd))],
            @[kVibeMenuEditMoveToTrash,   @(VibeShortcutMake(kVibeKeyCodeDelete, cmd))],
            @[kVibeMenuAddToPlaylist,     @(VibeShortcutMakeCharacter('o', cmd | NSEventModifierFlagShift))],
            @[kVibeMenuShowInFinder,      @(VibeShortcutMakeCharacter('r', cmd | NSEventModifierFlagShift))],
        ];
    });
    return table;
}

static inline NSArray<NSString *> *VibeShortcutIdentifiers(void) {
    static NSArray<NSString *> *identifiers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *all = [NSMutableArray array];
        for (NSArray *entry in VibeShortcutTable()) {
            [all addObject:entry[0]];
        }
        identifiers = all;
    });
    return identifiers;
}

// Which commands a held key repeats: the transport ones, which walk the
// track or the playlist, but Play Selected. A held Space, Tab, P or ⌘R would
// flutter.
static inline BOOL VibeShortcutCommandRepeats(NSString *identifier) {
    return VibeMenuValidationDomainForIdentifier(identifier) == VibeMenuValidationDomainTransport
            && ![identifier isEqualToString:kVibeMenuPlaySelected];
}

NS_ASSUME_NONNULL_END

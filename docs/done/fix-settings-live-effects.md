# Fix macOS settings live-effect duplication

Written and implemented 2026-08-23 for audit finding C4. The file:line anchors
below describe the pre-implementation tree at `bd2b0dc`.

## Outcome

Every store-first macOS setting write that needs immediate follow-up now uses
one direct funnel:

```objc
AppSettings.sharedInstance.alwaysOnTop = enabled;
[player applySettingsLiveEffects:VibeSettingsLiveEffectAlwaysOnTop];
```

Factory Reset uses that same funnel once, then restores geometry explicitly:

```objc
[AppSettings.sharedInstance resetToDefaults];
[player applySettingsLiveEffects:VibeSettingsLiveEffectAll];
[player resetWindowToDefaultShape];
```

The effect-to-behavior dispatch therefore exists in one implementation method
instead of being restated in every writer and again as a fifteen-call list in
`SettingsAdvancedViewController.resetSettings:`
(`SettingsAdvancedViewController.m:163-181`).

The solution is intentionally small:

- one `NS_OPTIONS` effect type;
- one `MainPlayerController` category with one application method;
- direct, synchronous calls from existing writers;
- no notification, observer, descriptor registry, dependency injection or new
  persisted state.

## The problem

`AppSettings` owns persistence only. A live setting usually has a second half
owned by the macOS shell:

- `alwaysOnTop` changes window levels;
- `pauseAtTrackEnd` must drop or re-park the successor prefetch;
- `crossfadeMilliseconds` must be copied into `AudioPlayer`;
- `useFolderArt` must invalidate `FolderArtResolver`'s cached setting;
- `convertEnabled` must hide or reveal the main Convert menu;
- display settings must repaint their affected surfaces.

Today each writer must know and call that second half. Factory Reset then repeats
all of those decisions manually. For example:

- Settings writes `pauseAtTrackEnd` and calls `applyEndOfTrackAction`
  (`SettingsPlaybackViewController.m:114-119`);
- Settings writes `useFolderArt` and calls `refreshFolderArt`
  (`SettingsFilesViewController.m:326-328`);
- Settings writes `convertEnabled` and calls a class method on `MainMenuBuilder`
  (`SettingsConvertViewController.m:53-58`);
- Reset separately knows all three, plus every other live hook.

Adding or changing a setting therefore requires a developer to rediscover every
writer and remember Reset. A missed call can leave NSUserDefaults holding one
value while the running app behaves as though it holds another. The two
load-bearing examples are folder art, whose hot-path cache otherwise never sees
the write, and On Track End, whose already-armed gapless splice otherwise keeps
the old behavior.

## Why this stays a direct call

Do not introduce an `AppSettingsDidChangeNotification` on macOS. The writers and
the affected state already share one owner, `MainPlayerController`, so a direct
main-thread call is simpler and has deterministic ordering. A notification would
add observer lifetime, delivery ordering and payload questions without removing
the need to map a setting to an effect.

Do not build a descriptor registry mapping defaults keys to selectors. These
effects are not uniform property assignments: some update audio state, some
redraw, some invalidate caches, one touches the menu bar, and Reset has an
ordering dependency around appearance. A registry would encode the same switch
less readably.

The effect set is not a snapshot of values. The application method reads current
values from `AppSettings` at the moment it runs, leaving normalization or a
consumer fallback in its existing home. That makes Reset identical to an
ordinary write.

## Part 1 — Add one live-effect API

Add a production category under the existing macOS MainWindow boundary:

```text
Vibe/Mac/MainWindow/MainPlayerController+Settings.h
Vibe/Mac/MainWindow/MainPlayerController+Settings.m
```

The directory is already a recursive macOS source entry, so this needs no
`project.yml` edit.

### 1.1 Effect set

Declare the effect set in the category header. The names describe observable
work, not defaults keys, because several settings share one repaint effect.

```objc
typedef NS_OPTIONS(NSUInteger, VibeSettingsLiveEffect) {
    VibeSettingsLiveEffectAlwaysOnTop      = 1UL << 0,
    VibeSettingsLiveEffectPitchRange       = 1UL << 1,
    VibeSettingsLiveEffectEndOfTrack       = 1UL << 2,
    VibeSettingsLiveEffectCrossfade        = 1UL << 3,
    VibeSettingsLiveEffectUIUpdateRate     = 1UL << 4,
    VibeSettingsLiveEffectWindowAppearance = 1UL << 5,
    VibeSettingsLiveEffectWaveformStyle    = 1UL << 6,
    VibeSettingsLiveEffectWaveformTheme    = 1UL << 7,
    VibeSettingsLiveEffectWindowTint       = 1UL << 8,
    // showFileInfo, showRemainingTime, showBPM, showKey, keyNotation and
    // keyColorsEnabled share one display pass.
    VibeSettingsLiveEffectTrackDisplay     = 1UL << 9,
    VibeSettingsLiveEffectFolderArt        = 1UL << 10,
    VibeSettingsLiveEffectConvertMenu      = 1UL << 11,
    VibeSettingsLiveEffectFXControls       = 1UL << 12,
    VibeSettingsLiveEffectAll              = NSUIntegerMax,
};

@interface MainPlayerController (Settings)
- (void)applySettingsLiveEffects:(VibeSettingsLiveEffect)effects;
@end
```

`All` deliberately sets every bit rather than restating a known-mask expression.
A future live-effect bit is then included in Factory Reset automatically. The
method ignores bits it does not recognize.

All enum constants carry the `Vibe` prefix because they are C-linkage symbols;
the Objective-C class remains unprefixed per repository vocabulary.

### 1.2 Effect-to-setting map

The effect set should stay compact by grouping settings that have the same live
consequence:

| Effect | Settings it covers | Application behavior |
| --- | --- | --- |
| `AlwaysOnTop` | `alwaysOnTop` | `applyAlwaysOnTop` |
| `PitchRange` | `pitchRange` | `applyPitchRange` |
| `EndOfTrack` | `pauseAtTrackEnd` | `applyEndOfTrackAction` |
| `Crossfade` | `crossfadeMilliseconds` | assign the normalized value to `audioPlayer.crossfadeMilliseconds` |
| `UIUpdateRate` | `uiUpdateHzCap` | `syncUITimerRate` |
| `WindowAppearance` | `windowAppearanceStyle` | apply the stored appearance to the window and redraw appearance-dependent content |
| `WaveformStyle` | `waveformStyle` | assign the stored identifier to `waveformView.waveformStyle` |
| `WaveformTheme` | `waveformTheme` and its four custom colors | `refreshWaveformTheme` |
| `WindowTint` | `windowTint` and its two custom colors | `refreshWindowTint` |
| `TrackDisplay` | `showFileInfo`, `showRemainingTime`, `showBPM`, `showKey`, `keyNotation`, `keyColorsEnabled` | run the existing `updateUI` funnel once |
| `FolderArt` | `useFolderArt` | `refreshFolderArt` |
| `ConvertMenu` | `convertEnabled` | `MainMenuBuilder.applyConvertMenuVisibility` |
| `FXControls` | `audioFXEnabled` | when off, clear every active FX state before hiding the menu and its child key equivalents; when on, restore those controls; the key monitor reads the same stored gate |

The child key equivalents are part of that effect, not an extra mechanism.
AppKit still matches keys below a hidden top-level menu, so hiding alone would
leave Q/W/E/R/T active. The helper clears and restores those equivalents while
menu validation and the key monitor enforce the same stored gate.

The `TrackDisplay` grouping is intentional. The current four public helpers
ultimately call either `updateUI` or `effectiveTempoDidChange`
(`MainPlayerController.m:711-715`, `:852-862`). These settings are changed by
discrete controls, not a frame-rate gesture, so one full display refresh is both
simple and cheap enough. It also removes the false distinction between “refresh
the BPM half” and “refresh the key half” when both methods currently execute the
same function.

### 1.3 Implementation and order

`MainPlayerController+Settings.m` imports:

- `MainPlayerController+Settings.h`;
- `MainPlayerControllerInternal.h`, for the existing `updateUI` funnel and
  waveform outlet;
- `MainPlayerController+Menus.h`, for theme refresh;
- `MainPlayerController+Transport.h`, for the FX state setters;
- `MainPlayerController+Window.h`, for appearance and level effects;
- `AppSettings.h`, `AudioPlayer.h`, `AudioWaveformView.h`, and
  `MainMenuBuilder.h`.

The implementation is one readable sequence of bit tests. Assert that it runs on
main; every current writer is main-confined and every effect touches UI or
main-owned orchestration.

```objc
- (void)applySettingsLiveEffects:(VibeSettingsLiveEffect)effects {
    NSAssert(NSThread.isMainThread,
             @"Settings live effects are main-thread only");
    AppSettings *settings = AppSettings.sharedInstance;

    if (effects & VibeSettingsLiveEffectAlwaysOnTop) {
        [self applyAlwaysOnTop];
    }
    if (effects & VibeSettingsLiveEffectPitchRange) {
        [self applyPitchRange];
    }
    if (effects & VibeSettingsLiveEffectEndOfTrack) {
        [self applyEndOfTrackAction];
    }
    if (effects & VibeSettingsLiveEffectCrossfade) {
        self.audioPlayer.crossfadeMilliseconds = settings.crossfadeMilliseconds;
    }
    if (effects & VibeSettingsLiveEffectUIUpdateRate) {
        [self syncUITimerRate];
    }
    if (effects & VibeSettingsLiveEffectWindowAppearance) {
        [self applyStoredAppearance];
    }
    if (effects & VibeSettingsLiveEffectWaveformStyle) {
        self.waveformView.waveformStyle = settings.waveformStyle;
    }
    if (effects & VibeSettingsLiveEffectWaveformTheme) {
        [self refreshWaveformTheme];
    }
    if (effects & VibeSettingsLiveEffectWindowTint) {
        [self refreshWindowTint];
    }
    if (effects & VibeSettingsLiveEffectTrackDisplay) {
        [self updateUI];
    }
    if (effects & VibeSettingsLiveEffectFolderArt) {
        [self refreshFolderArt];
    }
    if (effects & VibeSettingsLiveEffectConvertMenu) {
        [MainMenuBuilder applyConvertMenuVisibility];
    }
    if (effects & VibeSettingsLiveEffectFXControls) {
        if (!settings.audioFXEnabled) {
            self.lowKillBoostActive = NO;
            self.lowKillActive = NO;
            self.reverbSendActive = NO;
            self.delaySendActive = NO;
            self.shortDelaySendActive = NO;
        }
        [MainMenuBuilder applyFXMenuVisibility];
    }
}
```

Keep this order. It matches the current Reset path and, more importantly:

1. the window appearance settles before theme and tint re-resolve colors;
2. the waveform style settles before its theme refresh.

Window shape is deliberately outside this method. `resetWindowToDefaultShape`
writes `playlistShown` and `pitchPanelShown` and saves the frame, while applying
a settings effect must never persist anything.

Do not add coalescing logic for the rare `All` call. `refreshFolderArt` and
appearance application may cause additional redraws, as they do today, but
ordinary writes request one effect. Avoiding a couple of Reset-only redraws is
not worth making the central mapping conditional on other selected bits.

## Part 2 — Make application helpers effect-only

Two current APIs combine persistence and application. Split them so the central
method never writes defaults while applying defaults.

### 2.1 Window appearance

`MainPlayerController+Window.setAppearance:` currently has two meanings:

- with an `NSMenuItem`, parse and store the selected appearance;
- with nil, merely apply the already-stored value.

Add an effect-only `-applyStoredAppearance` method containing the current final
two lines (`MainPlayerController+Window.m:275-276`). Then:

- `setAppearance:` accepts a menu item, writes `windowAppearanceStyle`, and asks
  for `VibeSettingsLiveEffectWindowAppearance`;
- the Settings pane writes the chosen value itself and asks for the same effect;
- the central applier calls `applyStoredAppearance` directly;
- remove the special “nil sender means apply” convention and update the header
  comment.

This prevents recursion and makes every method name state whether it writes or
applies.

### 2.2 Waveform style and theme

`applyWaveformStyle:` and `applyWaveformTheme:` currently persist as well as
apply (`MainPlayerController+Menus.m:276-294`). Remove those combined methods.

- The waveform-style menu action writes the selected identifier, then requests
  `WaveformStyle`.
- The Appearance pane writes the popup identifier, then requests
  `WaveformStyle`.
- The central method assigns the stored style to the view; the view owns its
  fallback for an unknown identifier.
- The Appearance pane writes `waveformTheme` after seeding Custom colors, then
  requests `WaveformTheme`.
- Custom color wells request `WaveformTheme` after their color write.
- Keep `refreshWaveformTheme` as an effect-only method because non-setting events
  may also need to re-resolve colors.

An important incidental correction: Factory Reset currently calls
`applyWaveformStyle:` after clearing defaults, which writes the registered
default back into the persistent domain. The new effect-only path leaves Reset's
store genuinely cleared.

## Part 3 — Migrate every live writer

The mechanical rule at every applicable call site is:

```text
write setting -> request its named live effect -> update pane-only control state
```

Pane-only work such as hiding custom-color rows or disabling dependent controls
does not belong in the central applier.

### 3.1 Settings panes

| File and action | After writing, request | Pane-local work that remains |
| --- | --- | --- |
| `SettingsGeneralViewController.toggleAlwaysOnTop:` | `AlwaysOnTop` | none |
| `SettingsPlaybackViewController.onEndChanged:` | `EndOfTrack` | none |
| `SettingsPlaybackViewController.pitchRangeChanged:` | `PitchRange` | none |
| `SettingsPlaybackViewController.crossfadeChanged:` | `Crossfade` | none |
| `SettingsPlaybackViewController.toggleEnableFX:` | `FXControls` | none |
| `SettingsAppearanceViewController.toggleShowBPM:` | `TrackDisplay` | none |
| `SettingsAppearanceViewController.toggleShowKey:` | `TrackDisplay` | refresh the pane so notation/color controls enable or disable |
| `SettingsAppearanceViewController.appearanceChanged:` | `WindowAppearance` | none |
| `SettingsAppearanceViewController.waveformStyleChanged:` | `WaveformStyle` | none |
| `SettingsAppearanceViewController.waveformThemeChanged:` | `WaveformTheme` | seed missing colors, hide/show Custom rows, remeasure pane |
| `SettingsAppearanceViewController.customColorChanged:` | `WaveformTheme` | none |
| `SettingsAppearanceViewController.windowTintChanged:` | `WindowTint` | seed missing colors, hide/show Custom rows, remeasure pane |
| `SettingsAppearanceViewController.windowTintColorChanged:` | `WindowTint` | none |
| File-info, time, notation and key-color actions | `TrackDisplay` | none |
| `SettingsFilesViewController.albumArtSourceChanged:` | `FolderArt` | none |
| `SettingsConvertViewController.toggleEnabled:` | `ConvertMenu` | refresh pane enablement |
| `SettingsAdvancedViewController.refreshRateChanged:` | `UIUpdateRate` | none |

Each of these files imports `MainPlayerController+Settings.h`. Remove category or
collaborator imports that become unused. The Playback pane retains `AudioPlayer.h`
only to decide whether its restart caption is true for this run; Convert and
Advanced no longer need `MainMenuBuilder.h`.

### 3.2 Menu and direct window actions

Settings is not the only writer. Migrate the duplicate menu paths too, or the
central API would be a Settings-window convention rather than the one live-write
funnel:

- `MainPlayerController.toggleFileInfo:` writes, then requests `TrackDisplay`;
- `MainPlayerController.setPitchRange:` writes, then requests `PitchRange`;
- `MainPlayerController.toggleTimeDisplayMode:` writes, then requests
  `TrackDisplay`;
- `MainPlayerController+Window.toggleAlwaysOnTop:` writes, then requests
  `AlwaysOnTop`;
- `MainPlayerController+Window.setAppearance:` writes, then requests
  `WindowAppearance`;
- `MainPlayerController+Menus.setWaveformStyle:` writes, then requests
  `WaveformStyle`.

The menu actions remain the owners of translating menu identifiers into stored
values. The central applier owns only what happens after the value is stored.

### 3.3 In-process debug writers

Change the mac debug commands `set_folder_art` and `set_pause_at_track_end` from
calling their raw helpers to requesting `FolderArt` and `EndOfTrack`. They are
in-process writers and should exercise the same path as production UI.

Do not change CLI-process commands such as `set_appearance` and
`set_key_display` in `DebugClient.m`. Those intentionally persist values from a
short-lived process and either target the next launch or document that a running
app repaints only on its next normal refresh. They have no
`MainPlayerController` instance on which to apply an effect.

## Part 4 — Reduce Factory Reset to one application call

After `resetToDefaults`, replace the manual list at
`SettingsAdvancedViewController.m:165-181` with:

```objc
[self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectAll];
[self.playerController resetWindowToDefaultShape];
```

Keep the existing pane work after it:

1. resolve each pane's layout-only state;
2. refresh the selected Advanced pane;
3. recompute shared pane size.

That work updates Settings-window controls and layout; it is not an application
effect and does not belong in `MainPlayerController+Settings`.

`All` deliberately excludes nothing by a hand-maintained reset list. Settings
with no live effect simply have no bit test in the method. In particular:

- the audio FX graph and output-device preference retain their documented
  relaunch behavior; active FX state, the FX menu and keys follow
  `audioFXEnabled` immediately;
- `analyzeBPM` and `analyzeKey` are read by the next waveform decode;
- `folderOpenSort`, `skipBaseBars`, drag actions and conversion choices are read
  when the next corresponding action begins;
- no work is needed merely because those values were reset.

Window shape stays separate because `resetWindowToDefaultShape` mutates and
persists geometry. Ordinary playlist and pitch-panel actions already own that
state, so they do not request a live effect either.

## Part 5 — Remove obsolete public hooks

Once all writers use the central effect, remove the settings-only display
wrappers if no non-setting caller remains:

- `refreshFileInfoDisplay`;
- `refreshTimeDisplay`;
- `refreshBPMDisplay`;
- `refreshKeyDisplay`.

Their effect is now the single `TrackDisplay` branch calling `updateUI`.
Removing them makes `MainPlayerController.h` smaller and prevents a future writer
from bypassing the central mapping by choosing one old hook directly.

Keep lower-level methods that have genuine non-setting callers or encode
load-bearing behavior:

- `applyAlwaysOnTop` is also used during window initialization;
- `applyPitchRange` is used while building the pitch panel;
- `syncUITimerRate` is used by playback, fader and resize paths;
- `refreshWaveformTheme`, `refreshWindowTint` and `refreshFolderArt` remain
  effect-only operations with non-writing semantics;
- `applyEndOfTrackAction` remains the one implementation of successor re-parking.

These methods may move from the broad public header to the relevant category or
internal header when their external callers disappear, but do not turn that into
a larger access-control refactor. Remove only declarations proven unused by
`rg` and the build.

## Part 6 — Documentation

Update documentation in the same change so no file continues instructing a
writer to call a raw hook:

- `Vibe/Mac/Settings/CLAUDE.md` — add the one write/apply rule and name each
  pane's effect; describe Reset as `VibeSettingsLiveEffectAll`.
- `Vibe/Mac/MainWindow/CLAUDE.md` — add the Settings category to the category map
  and describe it as the only setting-to-effect mapping.
- `Vibe/Common/CLAUDE.md` — keep AppSettings as a passive store, but replace the
  “call whatever owns the state” wording with the macOS central effect funnel.
- `Vibe/Common/AppSettings.h` — update comments for On Track End, folder art,
  crossfade, tint and similar settings to name their effect instead of a raw
  controller method.
- `Vibe/Mac/Menu/CLAUDE.md`, `Vibe/Audio/Metadata/CLAUDE.md`,
  `Vibe/Mac/MainWindow/APPEARANCE.md` and root `CLAUDE.md` — replace direct-hook
  obligations with the corresponding effect flag while preserving the reason
  each effect is load-bearing.
- `MainPlayerController+Menus.h` and `MainPlayerController+Window.h` — document
  the new separation between menu actions that write and helpers that apply.

Do not describe the applier as an event bus. It is a synchronous method on the
macOS shell owner.

## Tests and verification

### Automated checks

No new host-less unit test should instantiate `MainPlayerController`; the engine,
window and menu are the behavior under test. The value of this change is that the
compiler and one live path now connect every writer to the mapping.

Run:

```bash
make test
make test-summary
make analyze CONFIG=Release
make build CONFIG=Release
make check-layout
make check-vocabulary
```

No string extraction is expected because the change adds no user-facing copy.

After migration, use `rg` to inspect every macOS AppSettings assignment,
including setters invoked through a local `AppSettings *settings` variable. Each
must fall into exactly one of these classes:

1. write followed by a `VibeSettingsLiveEffect` request;
2. read-on-next-use setting requiring no effect;
3. relaunch-applied setting;
4. action that already performed the live behavior before persisting its state;
5. output-device settlement recording an effect that already happened.

No live writer may call one of the raw effect helpers directly.

### Running-app verification

Use a Debug build and the debug command channel. Drive both Settings controls and
their duplicate menu actions where both exist.

1. **Always on top:** toggle from Settings and View; verify the main, Settings and
   About window levels move together.
2. **Pitch range:** switch 8/16 from Settings and Controls; verify stored range,
   fader range and current pitch clamp.
3. **On track end:** while a successor is prefetched, switch to Pause and verify
   the gapless arm drops; switch back and verify it can re-arm.
4. **Crossfade:** change each preset and verify the player reports/uses the new
   duration without relaunch.
5. **UI update cap:** change 3/30/60 and verify `dump_state.ui.uiUpdateHz` is
   recomputed under a short track or suitable window width.
6. **Appearance:** change from Settings and View; verify window appearance and
   appearance-dependent waveform/tint rendering.
7. **Waveform style and theme:** drive the popup/menu and custom colors; verify
   `dump_state.settings`, the renderer, and color changes agree.
8. **Track display:** toggle file info, remaining time, BPM, key notation and key
   colors; verify header text and menu checkmarks update immediately.
9. **Folder art:** toggle from Settings and `set_folder_art`; verify the resolver
   changes behavior without relaunch.
10. **Convert:** toggle Enabled and verify `dump_menu` reports the main Convert
    menu hidden or visible while context-menu validation follows.
11. **Audio FX controls:** launch with FX enabled, activate all five effects,
    switch it off in Settings, and verify every effect and indicator clears
    before `menu_fx` hides, its child `key` fields disappear, and Q/W/E/R/T stop
    changing effect state. Cover the independent low-kill-boost case too.
    Switch it back on and verify the menu and keys return with every effect
    still off because this run retains its graph; a run launched without a
    graph must still wait for relaunch.
12. **Factory Reset:** first make every live setting non-default, show both
    window panes and resize the window. Reset once, then verify every stored value,
    every live surface, Convert visibility, audio properties and the shipping
    window shape agree with defaults.
13. Close and reopen Settings after Reset and verify its controls reflect the
    same values without causing a second application pass.

Use `settings_open`, `settings_click`, `dump_settings_ui`, `click_menu`,
`dump_menu`, `dump_state`, screenshots and `check_consistency` as appropriate.
Follow the `vibe-debug` skill rather than coordinate clicking.

## Implementation order

1. Add `MainPlayerController+Settings.h/.m` with the effect enum and central
   method, preserving current effect order.
2. Add effect-only appearance application and split waveform write/apply APIs.
3. Migrate MainPlayerController menu/direct actions to store-then-effect.
4. Migrate each Settings pane and both in-process debug writers.
5. Replace Factory Reset's manual hook list with `VibeSettingsLiveEffectAll`.
6. Remove obsolete combined methods and settings-only display wrappers.
7. Update the directory, guarantee and API comments.
8. Run `rg`, automated checks and the running-app matrix.

Every step must compile before proceeding. Do not temporarily make
`AppSettings` post notifications or let Reset call both the old list and the new
funnel; either would hide a missing migration behind duplicate application.

## Files expected to change

New:

- `Vibe/Mac/MainWindow/MainPlayerController+Settings.h`
- `Vibe/Mac/MainWindow/MainPlayerController+Settings.m`

Production call sites and helpers:

- `Vibe/Mac/MainWindow/MainPlayerController.h`
- `Vibe/Mac/MainWindow/MainPlayerController.m`
- `Vibe/Mac/MainWindow/MainPlayerControllerInternal.h`
- `Vibe/Mac/MainWindow/MainPlayerController+Menus.h`
- `Vibe/Mac/MainWindow/MainPlayerController+Menus.m`
- `Vibe/Mac/MainWindow/MainPlayerController+Window.h`
- `Vibe/Mac/MainWindow/MainPlayerController+Window.m`
- `Vibe/Mac/MainWindow/TransportKeyMonitor.m`
- `Vibe/Mac/Settings/SettingsGeneralViewController.m`
- `Vibe/Mac/Settings/SettingsPlaybackViewController.m`
- `Vibe/Mac/Settings/SettingsAppearanceViewController.m`
- `Vibe/Mac/Settings/SettingsFilesViewController.m`
- `Vibe/Mac/Settings/SettingsConvertViewController.m`
- `Vibe/Mac/Settings/SettingsAdvancedViewController.m`
- `Vibe/Debug/Mac/DebugCommandTable.m`
- `Vibe/Mac/Menu/MainMenuBuilder.h`
- `Vibe/Mac/Menu/MainMenuBuilder.m`

Documentation:

- `CLAUDE.md`
- `.claude/skills/vibe-debug/SKILL.md`
- `Resources/Localizable.xcstrings` (developer comments only)
- `Vibe/Common/AppSettings.h`
- `Vibe/Common/CLAUDE.md`
- `Vibe/Common/VibeStrings.h` (developer comments only)
- `Vibe/Audio/CLAUDE.md`
- `Vibe/Audio/Metadata/CLAUDE.md`
- `Vibe/Mac/MainWindow/CLAUDE.md`
- `Vibe/Mac/MainWindow/APPEARANCE.md`
- `Vibe/Mac/Menu/CLAUDE.md`
- `Vibe/Mac/Settings/CLAUDE.md`

No `project.yml` or iOS source change is needed. The catalog changes only to keep
the two existing FX strings' developer comments accurate; every localized value
remains untouched.

## Acceptance criteria

- Every store-first in-process macOS writer that needs immediate follow-up
  requests a named `VibeSettingsLiveEffect` after storing the value.
- The effect-to-behavior dispatch exists only in
  `MainPlayerController+Settings.m`.
- Factory Reset contains one application call, one explicit shape reset and no
  manual list of raw hooks.
- Adding a future effect bit automatically includes it in `All`.
- Applying effects never writes NSUserDefaults or window geometry.
- Waveform style Reset no longer re-persists the registered default after the
  store was cleared.
- Appearance is applied through an effect-only method; nil sender is no longer a
  hidden “apply without writing” convention.
- Track-display settings share one clearly named refresh effect.
- Folder-art and On Track End retain their load-bearing immediate behavior.
- Active Audio FX state and controls clear immediately while the graph remains
  launch-time.
- Per-use, next-work and relaunch-only settings start no unnecessary work.
- Main-thread application is synchronous, with appearance and style settled
  before their dependent color refreshes.
- The Settings pane's own layout/control refresh remains outside the applier.
- Outside the deliberate FX state, control and caption changes, existing menus,
  debug commands and Settings controls produce the same visible behavior through
  the same effect funnel.
- Unit tests, Release analysis, vocabulary/layout checks and the macOS build pass.

## Non-goals

- Moving persistence out of `AppSettings`.
- Posting a settings-changed notification on macOS.
- Rebuilding the Audio FX graph or changing the output device live.
- Adding a generic defaults-key/selector registry.
- Refactoring every MainPlayerController category or internal method.
- Coalescing Reset-only redraws.
- Changing other Settings UI layout, strings or defaults.
- Changing iOS's notification-based display-settings flow.

## Rollback

This change has no persisted migration. Reverting the category and restoring the
direct hook calls returns to the previous behavior. A partial rollback is unsafe:
if the central call is removed from a writer without restoring its old raw hook,
the stored value and live app will diverge again. Revert call-site migration and
the central mapping together.

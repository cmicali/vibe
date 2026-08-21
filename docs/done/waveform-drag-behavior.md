# Waveform drag behavior setting

Written 2026-08-20, implemented the same day. The file:line anchors below are against branch `ios-app` at `a19c5c5` **with its uncommitted working tree**, before the implementation landed.

This plan is written to be executed phase by phase by an implementation agent. Each phase compiles, passes `make test`, and is verifiable on its own before the next begins. Read the root `CLAUDE.md`, `Vibe/WaveformUI/Mac/CLAUDE.md`, `Vibe/Mac/Settings/CLAUDE.md` and `Vibe/Common/CLAUDE.md` first; Phase 3 also needs the `vibe-strings` skill and Phase 0/4 the `vibe-debug` skill.

**Phase 0 finding (2026-08-20, answered by the user):** today a drag starting on the waveform moves the window **and** seeks on release — the release point is roughly the armed point in view coordinates because the window traveled with the cursor, so the containment test passes and the seek fires. That behavior is not worth keeping: **the setting offers two options only**, Drag window (the default) and Seek on drag. There is no `classic` identifier anywhere.

## The feature

A macOS setting choosing what a drag that starts on the waveform does. Two options:

1. **Drag window** (the default) — a drag moves the window; only a stationary click seeks. A drag past the hysteresis never seeks on release.
2. **Seek on drag** — the waveform becomes a scrubber: the drag follows the cursor, seeks on release, and the window does not move.

macOS-only. iOS has no window to drag and `WaveformScrubberView` already seeks on drag.

## How the code works today (all anchors verified at `a19c5c5`)

- `AudioWaveformView` handles only `mouseDown:` and `mouseUp:` (`Vibe/WaveformUI/Mac/AudioWaveformView.mm:88-118`). Mouse-down arms `_didClickInside` when the click lands inside the renderer's `seekHitBandForBounds:`; mouse-up inside the bounds fires `[self.delegate audioWaveformView:self didSeek:x/width]`. There is no `mouseDragged:`.
- The delegate is `MainPlayerController`, and the seek is one line: `[self.audioPlayer seekToPosition:self.audioPlayer.duration * percentage]` (`Vibe/Mac/MainWindow/MainPlayerController+Delivery.m:27-29`).
- The window is `movableByWindowBackground` (`Vibe/Mac/MainWindow/MainWindow.m:66`). The view reports `isOpaque` NO (`AudioWaveformView.mm:120-122`) and does **not** override `mouseDownCanMoveWindow`; `NSView`'s default answers YES for a non-opaque view, so a drag on the waveform moves the window today. Compare `SymbolButton.m:60`, `ArtworkImageView.m:21`, `PitchFaderView.m:43`, which each return NO precisely to opt out of that.
- Every presentation reset funnels through `resetWaveformContentState` (`AudioWaveformView.mm:219-225`), which clears `_didClickInside` so a mouse-up cannot seek after the track changed underneath it (`WaveformUI/Mac/CLAUDE.md`). Any new in-flight drag state joins that reset.
- The hover machinery (`setHoverHighlightX:`, `AudioWaveformRenderer.h:108`) already lights the waveform column under the cursor in both renderer families, with each family's own mechanism (`WaveformUI/Mac/CLAUDE.md`).

## Phase 0 — Characterize "current behavior"

Answered — see the finding at the top. A drag today moves the window *and* seeks on release; the setting drops that behavior rather than preserving it, so the popup has two options and no `classic` identifier exists.

## Phase 1 — The setting

**`Vibe/Common/AppSettings.h`**, inside the `#if TARGET_OS_OSX` block (adding a property means choosing a side — `Common/CLAUDE.md`; this one is mac-only):

```objc
// What a drag starting on the waveform does. Stable identifiers, never
// display names. drag_window (default) = window drag only, a moved mouse
// never seeks; seek = the waveform scrubs and the window stays put.
#define SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW    @"drag_window"
#define SETTINGS_VALUE_WAVEFORM_DRAG_SEEK      @"seek"
- (NSString *)waveformDragBehavior;
- (void)setWaveformDragBehavior:(NSString *)behavior;
```

**`Vibe/Common/AppSettings.m`**:

- Key macro `#define SETTING_WAVEFORM_DRAG_BEHAVIOR @"Settings.waveformDragBehavior"`. The key string is permanent once shipped — never rename it after the macro (`Common/CLAUDE.md` trap).
- Register the default in `registerMacDefaultsInto:` (the mac half of `registerDefaults`, `AppSettings.m:131-138`): value `SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW`.
- Getter normalizes on read, like `keyNotation`: an unknown stored string returns the default. Do **not** add it to the hot-path cache — it is read once per mouse-down, not per frame.

**`Vibe/Common/SettingsRules.h`** — add the pure decision so it is testable without a defaults store, following `VibeNormalizedPitchRange`'s shape (`SettingsRules.h:8`):

```objc
static inline NSString *VibeNormalizedWaveformDragBehavior(NSString * _Nullable stored);
```

returning `stored` when it matches one of the two identifiers, else `drag_window`. The getter calls it.

**Tests**: extend `SettingsRulesTests` (`Tests/`; read `Tests/CLAUDE.md` first): each valid identifier passes through, nil/garbage snaps to `drag_window`.

**Acceptance**: `make test`, `make check-vocabulary` (rule 3 — `SettingsRules.h` already has a `.m`-less allowlisted shape as a `*Rules.h`, so nothing new to allow).

## Phase 2 — Behavior in `AudioWaveformView`

All changes in `Vibe/WaveformUI/Mac/AudioWaveformView.mm` (+ ivars; internal header only if `+Loading` needs to see them — it shouldn't). The view reads `AppSettings.sharedInstance.waveformDragBehavior` per mouse-down and stashes it in an ivar for the gesture's duration, so the mode cannot change mid-drag.

### 2a. `mouseDownCanMoveWindow`

```objc
- (BOOL)mouseDownCanMoveWindow {
    // Seek-on-drag owns the drag; the other modes leave it to the window.
    return ![AppSettings.sharedInstance.waveformDragBehavior
              isEqualToString:SETTINGS_VALUE_WAVEFORM_DRAG_SEEK];
}
```

Note AppKit consults this from the *hit-tested view* on mouse-down; no caching needed. `AudioWaveformView.mm` already imports `AppSettings.h`.

### 2b. Drag-window mode: disarm the release seek

Snapshot the window's `frame.origin` and the view-local down point at mouse-down. In `mouseUp:` under `drag_window`, bail before the delegate call when either has moved more than a small hysteresis (~4pt, `hypot` of the delta). The window-origin check catches the server-side background drag, where the view-local point barely moves because the window traveled with the cursor; the local-point check covers any delivery mode where it doesn't.

### 2c. Seek-on-drag mode

Decision, made here so the agent doesn't have to: **track visually during the drag, seek the audio once on mouse-up.** Live audio scrubbing re-seeks the engine continuously and every seek runs a declick ramp; release-seek is predictable and cheap, and upgrading later touches only this view.

- Gate the *start* on `seekHitBandForBounds:` exactly as `mouseDown:` does today. Once armed, the drag tracks even if the cursor leaves the band or the view vertically — clamp x to `[0, bounds.width]`, like every system slider.
- Render the tracked position through the existing hover machinery: on each `mouseDragged:`, call `[_currentWaveformRenderer setHoverHighlightX:clampedX]`. Both families already draw it correctly and re-assert it across progress repaints (`WaveformUI/Mac/CLAUDE.md`). Do **not** touch `setProgress:` — real playback progress keeps painting underneath, which is correct for a not-yet-committed scrub, and avoids fighting the UI tick.
- `mouseUp:`: fire `didSeek:` with the clamped fraction (bypassing the `mouse:inRect:` containment test that today's stationary-click path uses — the drag may legitimately end outside the view), then clear the hover highlight if the cursor is outside the view.
- A drag in flight is presentation state: clear the armed/dragging ivars in `resetWaveformContentState` (`AudioWaveformView.mm:219`), alongside the existing `_didClickInside = NO`. A track change mid-drag must make the release a no-op.
- The gate on having a waveform at all (`!_waveform` checks in `mouseDown:`) already keeps empty/loading/parked states inert; keep it.

**Acceptance**: `make build`, then by hand or debug channel: in `seek` mode a drag does not move the window and release seeks to the release column; in `drag_window` mode a ≥hysteresis drag moves the window and does not seek; a stationary click seeks in every mode; a track change mid-drag kills the pending seek.

## Phase 3 — Settings UI

**`Vibe/Mac/Settings/SettingsAppearanceViewController.m`** — a popup beside the Waveform style row, same pattern as the style popup (`SettingsAppearanceViewController.m:46-56`): identifiers on `representedObject`, localized titles display-only.

- New row in the form grid (line 79-87): label + popup, width `kAppearancePopUpWidth`. Bump `kAppearancePaneHeight` (line 13) if the grid needs it — the design size is a minimum, but keep it honest.
- Action writes `AppSettings.sharedInstance.waveformDragBehavior = selectedItem.representedObject`. **No live-apply hook is needed** — the view reads the setting per mouse-down.
- `refreshFromSettings` selects by matching `representedObject` against the (normalized) getter, falling back to the default item like the style popup does (lines 106-124).

**Strings** — read the `vibe-strings` skill first, then declare in `Vibe/Common/VibeStrings.h`: a row label (suggest key family `settings.waveform_drag.*`: label "Waveform drag", options "Move window", "Seek") and run `make strings`. `make check-strings` and `make check-translations` must pass; translations for all catalog languages are part of this phase, per the skill.

**Acceptance**: `make check-strings`, `make check-translations`; `dump_settings_ui` on the appearance pane shows the popup with the two identifiers under `items[].represented`; `settings_click "Waveform drag" seek` flips it and `dump_state | jq .settings` reflects it (extend `dump_state`'s settings block if it doesn't already include new keys automatically — check `Vibe/Debug/`'s mac command table).

## Phase 4 — End-to-end verification

- `settings_click` through each identifier, then the Phase 2 acceptance matrix via the `drive`/`drag` verbs, asserting window frame and playback position from `dump_state` after each gesture.
- Both renderer families (`settings_click Waveform sonic_cirrus`, then the default `oversampling_detailed_x4`) in `seek` mode — the drag affordance is the hover column, whose mechanism differs per family.
- `make test`, `make analyze CONFIG=Release`, `make check-layout`, `make check-vocabulary`, `make build-ios` (nothing here may leak AppKit into shared code — all Phase 2 code is under `WaveformUI/Mac/`, all Phase 1 code inside the `TARGET_OS_OSX` block).

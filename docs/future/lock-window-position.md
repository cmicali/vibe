# Future: Lock window position

Written 2026-09-20 for [#46](https://github.com/cmicali/vibe/issues/46), planned but not implemented. Nothing in the repo has changed for it yet. The file:line anchors below are against `main` at `0e303170`. Re-check every anchor before acting.

Read the root `CLAUDE.md`, `Vibe/Mac/MainWindow/CLAUDE.md`, `Vibe/Mac/Settings/CLAUDE.md` and `Vibe/WaveformUI/Mac/CLAUDE.md` first. The string needs the `vibe-strings` skill, verification the `vibe-debug` skill.

## The feature

A switch in **Settings > General**, **Lock window position**, off by default. While it is on, the player window cannot be dragged: not by its background, the artwork, the waveform or the empty and loading states. macOS only; the Settings and About windows are unaffected.

Decided here:

- **Settings only, no menu item.** Always on Top has a View menu item and a switch; this has just the switch.
- **Position only.** The window stays resizable, so a drag on its left or top edge still moves that edge. The app's own size changes (Show Playlist, the pitch panel, View > Size and Factory reset's shape) keep working, since they set the frame directly.
- **Nothing the app does shifts a locked window sideways.** Today, opening the pitch panel or a wider Size preset against the right screen edge slides the window left to fit, and closing it never slides it back. While locked the slide is skipped, so the grown part may extend past the screen edge.
- **A waveform drag does nothing while locked** under "Dragging the waveform: Move window". A stationary click still seeks; a drag neither seeks nor moves. "Scrub through track" is unaffected.
- **A locked window whose display goes away is moved onto a remaining screen.** Without this it is stranded (finding 3 below).

## What `movable = NO` covers, and what it does not

`NSWindow.movable` is the whole mechanism, but it covers less than its name says. From its comment in `NSWindow.h` and AppKit's own code, disassembled on macOS 27:

1. **It stops the background drag.** `setMovable:` resets the window's drag region (`_updateWindowCanServerSideDrag` → `_setNeedsToResetDragMargins:`), and `_draggableFrame`, which feeds that region, checks `isMovable`; `movableByWindowBackground` is ignored while the window is not movable. That covers the background, the artwork with no track loaded (`ArtworkImageView.mouseDownCanMoveWindow` answers YES then), and any other view that lets a mouse-down move the window.
2. **It does not stop `performWindowDragWithEvent:` on macOS 26 and later.** The call goes straight to the window server (`_dragWindowRelativeToMouseDown:options:` → `SLSPackagesDragWindowRelativeToMouse`), and nothing on that path checks `isMovable`. Nucleus documents the call as needing `isMovable` only before macOS 26, Lockbook relies on it moving a non-movable window, and Chromium and Ladybird check `isMovable` themselves before calling it. **The waveform moves the window through this call.** Not drag-tested: a real drag needs synthesized input, which belongs on a dedicated test Mac (the rule `gesture_test` already follows).
3. **The system will not rescue it.** A non-movable window is not moved or resized when displays are reconfigured (`NSWindow.h`; `_adjustWindowToScreen` checks `isMovable`). Unplug the display a locked window is on and the window stays where no screen is. Nothing in the app reaches it: `frameKeptOnScreen:` needs `self.screen`.
4. **Code can still set the frame, and a resizable window can still be resized** (`NSWindow.h`).
5. **Not relevant:** macOS adds its tiling items (Fill, Center, Move & Resize) only to a Window menu, which the app does not have, and edge tiling starts from a drag. Window managers that move windows through Accessibility (Rectangle, Magnet) are probably not stopped, since no movability check turned up on that path. That is accepted: they are an explicit user action.

To re-check on a later macOS: `dyld_info -arch arm64e -disassemble /System/Library/Frameworks/AppKit.framework/AppKit`, then name each `objc_msgSend$` stub the path calls by decoding its `adrp x1`/`add x1` pair at runtime; the address the pair forms is the selector. Look for `isMovable` between `performWindowDragWithEvent:` and the `SLS` call.

Sources: [Nucleus `window_drag.m`](https://github.com/NucleusFramework/Nucleus/blob/HEAD/decorated-window-tao/src/main/native/macos/window_drag.m), [Lockbook `macos_window.rs`](https://github.com/lockbook/lockbook/blob/HEAD/clients/desktop/src/shell/macos_window.rs), [Ladybird `MacWindow.mm`](https://github.com/LadybirdBrowser/ladybird/blob/HEAD/UI/Qt/MacWindow.mm).

## How the window moves today (anchors at `0e303170`)

- `MainWindow.m:83` turns on `movableByWindowBackground`. Views opt out with `mouseDownCanMoveWindow`: `SymbolButton`, `PitchFaderView`, `PlaylistDropZoneView` and `AudioWaveformView`, whose constant NO is a trap (`WaveformUI/Mac/CLAUDE.md`).
- `AudioWaveformView.mm` hands the gesture to `performWindowDragWithEvent:` in three places: with no waveform (`:135`), outside the seek band (`:151`), and past the hysteresis under Move window (`:171`). That last one disarms the press first (`:170`), so a declined handoff leaves a drag that neither seeks nor moves, which is the behavior decided above, for free.
- `MainWindow.m:102-105` restores the autosaved frame before `loadSettings`. The controller's build applies window settings after that (`MainPlayerController.m:342`, `applyAlwaysOnTop`), so a lock applied there never interferes with the restore.
- `frameKeptOnScreen:` (`MainWindow.m:308-314`) is the one slide. `setContentWidth:animate:` (`:295`), `setPitchPanelShown:animate:` (`:331`) and `resetToDefaultShape` (`:353`) call it.
- **Always on Top is the template**, site for site: the setting at `AppSettings+Mac.h:200-205` and `AppSettings+Mac.m:21`, `:77` and `:688-694`; the effect bit at `MainPlayerController+Settings.h:11` and its branch at `MainPlayerController+Settings.m:42-44`; `applyAlwaysOnTop` at `MainPlayerController+Window.m:281-285`; the switch at `SettingsGeneralViewController.m:39`, `:82`, `:105`, `:164` and `:238-241`; the string at `VibeStrings.h:237`.

## Implementation

One commit; each step compiles.

### 1. The setting

`AppSettings+Mac.{h,m}`: `- (BOOL)windowPositionLocked;` and `- (void)setWindowPositionLocked:(BOOL)locked;`, key `MainWindow.positionLocked`, default NO beside `SETTING_ALWAYS_ON_TOP` in the registered defaults. The header comment names the one writer (Settings > General) and the effect that acts on it, as `alwaysOnTop`'s does. The key is permanent once shipped.

### 2. The effect and the apply

- `MainPlayerController+Settings.h`: `VibeSettingsLiveEffectWindowLock = 1UL << 24` (`1UL << 23` is `BitPerfect`). Not part of `ThemeApply`, since no theme carries it. Factory reset needs nothing: it requests `VibeSettingsLiveEffectAll`.
- `MainPlayerController+Settings.m`: the branch, beside Always on Top's, calling `applyWindowLock`.
- `MainPlayerController+Window.{h,m}`: `applyWindowLock` sets `self.window.movable = !AppSettings.sharedInstance.windowPositionLocked`. Called from the build beside `applyAlwaysOnTop`, and from the effect. No action method, since only the switch writes the setting.

**`movable` is the lock's only state.** `MainWindow` never reads the setting; the three rules in step 3 all read `self.isMovable`.

### 3. The window enforces the lock (`MainWindow.m`)

**a. The drag handoff.** This is the whole waveform fix. `AudioWaveformView` does not change, and any later caller is covered too.

```objc
// TRAP: from macOS 26 this call ignores isMovable and starts the drag in the
// window server anyway, so the waveform's handoff would move a locked window.
// The lock is enforced here, for every caller.
- (void)performWindowDragWithEvent:(NSEvent *)event {
    if (self.isMovable) {
        [super performWindowDragWithEvent:event];
    }
}
```

**b. The rescue.** Observe `NSApplicationDidChangeScreenParametersNotification` (object `NSApp`) beside `_resizeObserver`, added in `init` and removed in `dealloc`, and call this from it. Test the screens directly rather than trusting `self.screen` straight after a reconfiguration.

```objc
// TRAP: the system never moves a non-movable window when displays change
// (NSWindow.h, isMovable), so a locked window whose display goes away would
// be left where no screen is, out of reach.
- (void)keepLockedWindowOnScreen {
    NSScreen *primary = NSScreen.screens.firstObject;
    if (self.isMovable || !primary) {
        return;
    }
    for (NSScreen *screen in NSScreen.screens) {
        if (NSIntersectsRect(screen.visibleFrame, self.frame)) {
            return;
        }
    }
    // Centered, size kept, with the top edge (traffic lights, transport) never
    // above the visible area.
    NSRect visible = primary.visibleFrame;
    NSRect frame = self.frame;
    frame.origin.x = NSMidX(visible) - NSWidth(frame) / 2;
    frame.origin.y = MIN(NSMidY(visible) - NSHeight(frame) / 2, NSMaxY(visible) - NSHeight(frame));
    [self setFrame:frame display:YES];
}
```

**c. No slide.** `frameKeptOnScreen:` returns the frame unchanged while `!self.isMovable`; its comment says a locked window stays put and the growth may extend past the screen edge.

### 4. The switch (`SettingsGeneralViewController.m`)

Always on Top's four sites, line for line: a `_lockWindowPositionSwitch` ivar built with `switchWithAction:@selector(toggleLockWindowPosition:)`; a row in the Window section directly under Keep window on top; its state in `refreshFromSettings`; and an action that writes the setting and requests `VibeSettingsLiveEffectWindowLock`. No caption.

### 5. The string

`VibeStrings.h`, beside `STR_SETTINGS_ALWAYS_ON_TOP`: `STR_SETTINGS_LOCK_WINDOW_POSITION`, key `settings.general.lock_window_position`, English "Lock window position". Its comment says the switch stops the player window from being dragged, that resizing still works, and that it is sentence case like the other switches. Then `make strings`, and translate the other 29 languages in the catalog, matching the word for "window" each language already uses in `settings.general.always_on_top`. `make check-translations` must pass.

### 6. Debug and docs

- `DebugStateDump.m:143`: add `movable` to the `window` block beside `frame`, so `dump_state` reports it. That is the whole debug change: `settings_click` already addresses a switch by its row title.
- `Vibe/Mac/Settings/CLAUDE.md`, the General paragraph: the switch and its `WindowLock` effect.
- `Vibe/Mac/MainWindow/CLAUDE.md`, The window: the lock, `movable` as its only state, and both traps.
- `Vibe/WaveformUI/Mac/CLAUDE.md`, Drag behavior: the window may decline the handoff, and a declined Move window drag does nothing by design.

## Verification

- `make test`, `make analyze CONFIG=Release`, `make check-layout`, `make check-vocabulary`, `make check-strings`, `make check-translations` and `make build-ios`.
- Debug channel, Debug build: `settings_open general`, `settings_click "Lock window position" on`, and `dump_state` shows `window.movable` false; off, and it is true. Relaunch with it on: false at launch, with the autosaved frame restored. Factory reset: true.
- No slide: lock the window against the right screen edge, `click_menu` a wider View > Size preset, and toggle the pitch panel; the frame's x must not change. Do not use `set_window_width` for this. `VibeWindowFrameForBodyWidth` (`DebugCommandTable.m:92`) computes its own frame, slide included.
- By hand, since a real drag cannot be synthesized on a shared desktop: drag the background, the artwork with no track loaded, the waveform under both drag settings, its margins outside the seek band, and the empty state. The window must not move, a click on the waveform still seeks, and the edges still resize. Then lock the window on an external display and unplug it: the window must land on the remaining screen.

## Budget

About 80 lines of code, comments included, across 11 files, plus one catalog key (about 186 lines of JSON across 30 languages). No new files or types. **It removes nothing**: it is a new preference, and Always on Top is its template, not something it replaces.

One consolidation is available if wanted: declaring `frameKeptOnScreen:` in `MainWindow.h` would let `VibeWindowFrameForBodyWidth` drop its copy of the slide, and `set_window_width` would honor the lock.

## Open questions

1. Should the rescue remember the locked spot and put the window back when its display returns? As planned it is one-way: undock, and the window moves to the remaining screen and stays there.
2. Is skipping the slide right when it leaves the pitch panel partly off-screen? The alternative keeps the slide and undoes it when the panel closes, which means remembering the offset.

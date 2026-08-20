# Future: "On artwork drag" setting

Written 2026-08-20, planned but not implemented. Nothing in the repo has changed for it yet. The file:line anchors below are against branch `ios-app` at `a19c5c5` **with its uncommitted working tree**. Re-check every anchor before acting.

This plan is written to be executed phase by phase by an implementation agent. Each phase compiles, passes `make test`, and is verifiable on its own. Read the root `CLAUDE.md`, `Vibe/Mac/Controls/CLAUDE.md`, `Vibe/Mac/Settings/CLAUDE.md`, `Vibe/Util/Mac/CLAUDE.md` and `Vibe/Common/CLAUDE.md` first; Phase 3 also needs the `vibe-strings` skill.

## The feature

A macOS setting choosing what dragging the album artwork out of the window delivers to the destination:

1. **Copy file** (default — today's behavior) — the audio file itself; dropping on Finder copies the file.
2. **Copy file path** — the file's POSIX path as plain text.
3. **Copy Artist / Title** — the track's single-line name ("Artist - Title", or the filename-derived line when untagged) as plain text.

macOS-only: the drag-out source is `ArtworkImageView`, a mac control; iOS has no drag-out artwork surface.

## How the drag works today (anchors verified at `a19c5c5`)

- `ArtworkImageView` (`Vibe/Mac/Controls/ArtworkImageView.m`) is the foreground art card and an `NSDraggingSource`. Mouse-down records a pending event (refusing the transport-button exclusion band at the art's bottom, line 47); `mouseDragged:` starts the session after a 3pt hysteresis (lines 56-68); a plain click never drags.
- The payload is the view's `fileURL`, written straight in as the `NSDraggingItem`'s pasteboard writer (line 90). The drag ghost is a 48pt art icon plus a filename label from `NSDraggingImageComponent+Util` (lines 92-102).
- **The security-scope dance is load-bearing** (lines 78-85, 113-117, 126-129): `startAccessingSecurityScopedResource` is called before the session and released only in `draggingSession:endedAtPoint:operation:`, on the exact URL instance the start took on (`_securityScopedURL`), because the drag is async and the receiver reads the file after the drop. An unbalanced stop over-releases the sandbox extension.
- Drags are copy-only outside the app and `NSDragOperationNone` inside it (lines 119-124) — a drop back onto Vibe's own window must not re-enter the open funnel.
- `ArtworkDisplayController` sets `_artworkView.fileURL = track.url` on every track display (`Vibe/Mac/MainWindow/ArtworkDisplayController.m:344`), deliberately following the *displayed track* even while art is still resolving, so a drag during the gap exports the track the header names.
- The text the third option wants already has a single home: `AudioTrack.singleLineTitle` (`Vibe/Audio/AudioTrack.m:191-199`) — the localized `STR_LABEL_TRACK_ARTIST_TITLE` ("%@ - %@") when artist and title are both tagged, else the underscore-cleaned filename-derived title. It is exactly what Edit > Copy Name copies (`Util/Mac/TrackCommands.m:25-30`).
- `NSDraggingImageComponent+Util` already has the general `labelWithString:imageRect:` that `labelWithFile:` wraps (`Util/Mac/NSDraggingImageComponent+Util.m:12-14`).

## Phase 1 — The setting

**`Vibe/Common/AppSettings.h`**, inside the `#if TARGET_OS_OSX` block (adding a property means choosing a side — `Common/CLAUDE.md`; this is mac-only):

```objc
// What dragging the album art out of the window delivers. Stable identifiers,
// never display names. copy_file (default) = the audio file itself, as today;
// copy_path = the POSIX path as text; copy_artist_title = the track's
// single-line name as text.
#define SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE          @"copy_file"
#define SETTINGS_VALUE_ARTWORK_DRAG_COPY_PATH          @"copy_path"
#define SETTINGS_VALUE_ARTWORK_DRAG_COPY_ARTIST_TITLE  @"copy_artist_title"
- (NSString *)artworkDragAction;
- (void)setArtworkDragAction:(NSString *)action;
```

**`Vibe/Common/AppSettings.m`**:

- Key macro `#define SETTING_ARTWORK_DRAG_ACTION @"Settings.artworkDragAction"` — permanent once shipped (`Common/CLAUDE.md` trap: a stored key never follows a macro rename).
- Register `copy_file` as the default in `registerMacDefaultsInto:` (the mac half of `registerDefaults`, `AppSettings.m:131-138`).
- Getter normalizes on read. Not hot-path — read once per drag start; do not add it to the run-loop cache.

**`Vibe/Common/SettingsRules.h`** — the pure decision, testable without a defaults store (pattern: `VibeNormalizedPitchRange`, `SettingsRules.h:8`):

```objc
static inline NSString *VibeNormalizedArtworkDragAction(NSString * _Nullable stored);
```

returning `stored` when it matches one of the three identifiers, else `copy_file`. The getter calls it.

**Tests**: extend `SettingsRulesTests` (read `Tests/CLAUDE.md` first): each identifier passes through; nil/garbage snaps to `copy_file`.

**Acceptance**: `make test`, `make check-vocabulary`, `make build-ios` (the property is inside the platform block; iOS must not see it).

## Phase 2 — The payload switch in `ArtworkImageView`

All changes in `Vibe/Mac/Controls/ArtworkImageView.{h,m}` plus one line in `ArtworkDisplayController`.

### 2a. Give the view the text it may need

The view holds `fileURL` but not the track name, and a control should not reach into the model. Add a second copy property beside `fileURL`:

```objc
@property (copy, nullable) NSString *trackDisplayName;   // singleLineTitle of the displayed track
```

and set it at the same site that sets `fileURL` (`ArtworkDisplayController.m:344`):

```objc
_artworkView.trackDisplayName = track.singleLineTitle;
```

It follows the displayed track for the same reason `fileURL` does — the comment above line 344 applies to both; extend it rather than duplicating it.

### 2b. Switch the pasteboard writer in `beginDragWithEvent:`

Read the setting once at drag start into a local (the mode must not change mid-drag). `AudioWaveformView.mm` shows the import pattern for `AppSettings.h`; this file doesn't import it yet.

- `copy_file` — exactly today's code path, untouched: security-scope start, `fileURL` as the writer, `labelWithFile:` ghost label.
- `copy_path` — writer is `self.fileURL.path` (`NSString` conforms to `NSPasteboardWriting`; a text drop lands as plain text, and a drop on the Finder makes a standard `.textClipping`). **Skip the security-scope dance entirely** — no receiver reads the file, and `_securityScopedURL` stays nil so the end-of-session stop remains balanced (it is already nil-safe, line 127).
- `copy_artist_title` — writer is `self.trackDisplayName`; bail out of the drag (return before the session starts) if it is empty. Skip the security scope here too. Ghost label uses the existing `labelWithString:trackDisplayName imageRect:` instead of `labelWithFile:` so the ghost shows what the drop will produce.

Everything else stays: the 48pt art icon, the hysteresis, the transport exclusion band, `mouseDownCanMoveWindow`/`acceptsFirstMouse` gating on `fileURL` (all three modes need a track, and `fileURL` is the "have a track" signal), copy-only-outside/none-inside operation masks.

Keep the switch flat inside `beginDragWithEvent:` — three cases choosing `(id<NSPasteboardWriting> writer, NSDraggingImageComponent *label, BOOL wantsSecurityScope)`. It is not worth a `*Rules.h` seam: the decision is a dictionary lookup and the interesting parts (pasteboard writers, security scope) are untestable host-side anyway.

**Acceptance**: `make build`, then by hand: with each mode selected via `defaults write com.commonwealthrecordings.Vibe Settings.artworkDragAction <id>` (no live-apply needed — the view reads per drag), drag the art onto (a) Finder → file copy / text clipping / text clipping, (b) TextEdit → file path text / name text, (c) Vibe's own window → nothing happens in every mode. Confirm a drag of an untagged file in `copy_artist_title` mode delivers the filename-derived line, and that a security-scoped file (opened from a granted cloud folder) still file-drags correctly in `copy_file` mode.

## Phase 3 — Settings UI

**Pane**: General (`Vibe/Mac/Settings/SettingsGeneralViewController.m`) — this is window-interaction behavior, not appearance; General already holds the window-level always-on-top toggle. A popup row labeled "On artwork drag", mirroring Playback's "On track end" naming. Follow the identifier-on-`representedObject` pattern (`SettingsAppearanceViewController.m:46-56`), action writing `AppSettings.sharedInstance.artworkDragAction`, `refreshFromSettings` re-selecting from the normalized getter with the default-item fallback (pattern at `SettingsAppearanceViewController.m:106-124`). **No live-apply hook**: the view reads the setting at drag start.

**Strings** (read the `vibe-strings` skill first, then edit `VibeStrings.h`, then `make strings` + translations):

- Row label: new `settings.artwork_drag.label` — "On artwork drag".
- Option 1: **reuse `STR_MENU_EDIT_COPY_FILE`** ("Copy File", `VibeStrings.h:94`) — Settings reuses menu strings where the word is the same (`Mac/Settings/CLAUDE.md`).
- Options 2 and 3: new `settings.artwork_drag.copy_path` ("Copy File Path") and `settings.artwork_drag.copy_artist_title` ("Copy Artist / Title"). Do **not** reuse `STR_MENU_EDIT_COPY_NAME` for option 3 — same payload, different word, and the menu string must stay "Copy Name".

**Acceptance**: `make check-strings`, `make check-translations`; `dump_settings_ui` on the general pane shows the popup with the three identifiers under `items[].represented`; `settings_click "On artwork drag" copy_path` flips it and `dump_state | jq .settings` reflects it (extend the `dump_state` settings block in `Vibe/Debug/`'s mac command table if new keys don't surface automatically).

## Phase 4 — Final verification

- `settings_click` through all three identifiers, asserting the stored setting after each.
- The Phase 2 manual drag matrix (out-of-app drops cannot be driven by the debug channel's `drag` verb — it posts into Vibe's own window — so this stays manual; note the result here).
- Regression: plain click on the art still never drags; a mouse-down in the transport exclusion band still starts a window drag; a drag started mid-track-change exports the track the header names (the `fileURL`/`trackDisplayName` pair is reassigned together, so they cannot disagree).
- `make test`, `make analyze CONFIG=Release`, `make check-layout`, `make check-vocabulary`, `make build-ios`.

# Future: Waveform color themes

Written 2026-08-20, planned but not implemented. Nothing in the repo has changed for it yet. The file:line anchors below are against branch `ios-app` at `a19c5c5` **with its uncommitted working tree**. Re-check every anchor before acting.

This plan is written to be executed phase by phase by an implementation agent. Each phase compiles, passes `make test`, and is verifiable on its own. Read the root `CLAUDE.md`, `Vibe/WaveformUI/CLAUDE.md` (and its `Mac/` and `iOS/` children), `Vibe/Mac/Settings/CLAUDE.md` and `Vibe/Common/CLAUDE.md` first; Phase 4 needs the `vibe-strings` skill, verification the `vibe-debug` skill.

## The feature

A waveform color theme setting — a dropdown with four choices:

1. **White** (default) — today's monochrome look: white-based in dark mode, black-based in light.
2. **Orange** — Sonic Cirrus's played-orange palette, available to every style.
3. **Album art** — played color derived from the current track's artwork.
4. **Custom** — two color pickers, played and unplayed.

The theme is a *palette*; the existing waveform style setting stays the *geometry*. Today the two are conflated — Sonic Cirrus is both a bar layout and the only owner of the orange — and this feature is the split.

**Resolved design decisions** (so implementation doesn't stall):

- **Theme always beats the style's built-in palette.** Sonic Cirrus under the White theme is monochrome. To keep existing Sonic Cirrus users' windows unchanged, a one-time migration (Phase 3) writes the Orange theme for anyone whose stored style is `sonic_cirrus` and who has no theme key yet.
- **One custom pair applies to both light and dark as-is.** Per-appearance pairs double the UI for little gain.
- **The setting is shared** (both platforms render waveforms; `waveformStyle` already sits above the platform split at `AppSettings.h:19-22`), but iOS ships in a later phase, and Album art is macOS-only until an iOS extraction exists (Phase 6).
- **Seek/scrub, loading shimmer, midline and empty placeholder are not themed.** They are chrome; their alphas live in `WaveformMidline.h`.

## Where colors live today (anchors verified at `a19c5c5`)

- **Detailed family** (`DetailedAudioWaveformRenderer.mm`): one monochrome base — white when dark, black when light (line 195) — with played and unplayed as vertical alpha ramps of that base built in `playedGradientColors:isDark:` / `unplayedGradientColors:isDark:` (lines 209-224; constants `kPlayedTop = 1.0`, `kUnplayedTop = 0.5`, `kBottomAlpha = 0.45`). Hover column = base at full alpha (line 200).
- **Sonic Cirrus** (`SonicCirrusWaveformRenderer.mm:91-105`): hardcoded played pair — top `(1, 0.45, 0)`, bottom `(1, 0.75, 0.585, 0.8)` — over a monochrome unplayed pair (base at 0.89 / 0.55). Hover = base at 1.0.
- **Basic** re-aims the same monochrome fade.
- Everything funnels through `updateColors:(BOOL)isDark` (`AudioWaveformRenderer.h:75`); `lastProgressBoundary = -1` is the existing force-full-repaint sentinel after a color change (`AudioWaveformRenderer.h:61`).
- The iOS scrubber's settled fast path bakes the Detailed gradient into a bitmap via `envelopeSamplesForWaveform:` / `newEnvelopeImageForSize:scale:samples:` / `unplayedOverPlayedOpacity` (`DetailedAudioWaveformRenderer.h:42-46`, `.mm:365-440`), with a standing **pixel-identical to the live layers** guarantee (`WaveformUI/CLAUDE.md`). The scrubber already invalidates that bitmap on appearance change (`WaveformScrubberView.mm:1097-1110`).
- macOS already extracts and caches a per-artwork dominant color: `NSImage.dominantColor` (`Util/Mac/NSImage+Util.m:78`), memoized by `ArtworkDisplayController` (`ArtworkDisplayController.m:252-271`).
- Style apply path to copy: `MainPlayerController.applyWaveformStyle:` sets the view then persists (`MainPlayerController+Menus.m:212-218`); the Appearance pane calls it (`SettingsAppearanceViewController.m:158-160`).
- There is no hex-color helper in the codebase yet; Phase 3 adds one.

## Phase 1 — The theme model

New files in `Vibe/WaveformUI/` (shared directory → compiles into both targets → **must be AppKit/UIKit-free apart from `VibeColor`**, the `PlatformTypes.h` alias):

**`WaveformTheme.h`/`.m`** — an immutable value object (ObjC, not a header-only seam; it holds platform color types and construction logic):

```objc
@interface WaveformTheme : NSObject
@property (readonly) VibeColor *playedColor;    // full-alpha base hue for the played side
@property (readonly) VibeColor *unplayedColor;  // full-alpha base hue for the unplayed side
@property (readonly) VibeColor *hoverColor;     // derived, see below
+ (WaveformTheme *)themeForIdentifier:(NSString *)identifier
                               isDark:(BOOL)isDark
                         artworkColor:(nullable VibeColor *)artworkColor
                          customPlayed:(nullable VibeColor *)played
                        customUnplayed:(nullable VibeColor *)unplayed;
@end
```

Resolution rules, all inside that one constructor so there is exactly one home:

- `white` → played = unplayed = white when dark / black when light. **This must reproduce today's Detailed output exactly** once Phase 2 rebuilds the ramps from theme colors — same base, same alphas.
- `orange` → played = Sonic Cirrus's orange hue; unplayed = the monochrome base. (The Sonic Cirrus top/bottom pair becomes a *derivation* in Phase 2, not two stored colors.)
- `album_art` → played = the supplied `artworkColor` after a legibility clamp (below); nil or degenerate falls back to `white`'s answer. Unplayed = monochrome base.
- `custom` → the two supplied colors, nil falling back to `white`'s answer.
- **Legibility clamp** for album art: convert to HSB; if saturation < ~0.15 or brightness outside a per-appearance window (too dark to read on the dark backdrop, too bright on the light one), nudge brightness into the window; if still degenerate (grayscale art), fall back to white. Exact thresholds are tuning — pick initial values, verify visually in Phase 5.
- **Hover rule**: hover must stay brighter than both resting colors under *any* palette (today it is "base at full alpha", which a near-white custom played color would swallow). Rule: hover = playedColor at full alpha, brightness-shifted away from playedColor until the brightness delta clears ~0.25, direction chosen by appearance.

The alpha ramps stay in the renderers — the theme supplies *hues*, each family keeps deriving its own gradient alphas from them, which is what preserves pixel-identity for White.

**Tests** (`Tests/`, read `Tests/CLAUDE.md` first — pure logic, host-less; `VibeColor` is fine, it aliases per platform): white reproduces the current base colors both appearances; orange played hue matches the Sonic Cirrus constants; album-art fallback on nil/gray; custom fallback on nil; hover contrast property holds for black, white, and the orange.

**Acceptance**: `make test`, `make build-ios` (no AppKit leak), `make check-vocabulary`.

## Phase 2 — Renderers consume the theme

- `AudioWaveformRenderer` gains a `theme` property (strong, `WaveformTheme *`) and `updateColors:` re-derives from it; the initializer takes it or the view sets it immediately after init. Base class stores it; keep `isDark` as-is (the theme is resolved per appearance *outside*, but renderers still branch on `isDark` for non-palette decisions).
- **Detailed** (`DetailedAudioWaveformRenderer.mm`): `_gradientColor` splits into played/unplayed bases from the theme; `playedGradientColors:`/`unplayedGradientColors:` keep their alpha constants but ramp the theme hues. Hover column uses `theme.hoverColor`. **The envelope bake (`.mm:365-440`) must use the same theme-derived stops** — it duplicates the live gradient on purpose; change both together or the iOS scrubber's settled bitmap diverges from the live layers (`WaveformUI/CLAUDE.md` guarantee).
- **Sonic Cirrus** (`SonicCirrusWaveformRenderer.mm:91-105`): the played top/bottom pair becomes a derivation from `theme.playedColor` (top = the hue; bottom = the hue blended toward white at the current ratio — compute the blend that reproduces `(1, 0.75, 0.585, 0.8)` from `(1, 0.45, 0)` and apply it generically). Unplayed pair from `theme.unplayedColor` at the existing 0.89/0.55 alphas. `restingColorForBar:` and the hover restore path need no structural change.
- **Basic**: same substitution for its fade.
- The mac view (`AudioWaveformView.mm`) resolves the theme (settings + appearance + current artwork color) in `updateAppearance`/`setWaveformStyle:` and hands it down; `updateColors:` + the `-1` boundary sentinel already handle the full repaint.

**Acceptance**: with no settings UI yet, force themes via `defaults write` on the (Phase 3) key or a temporary hardcode; screenshot both families × both appearances via the `vibe-debug` skill and confirm White is pixel-identical to a pre-change screenshot (`compare` or eyeball at 2x). `make analyze CONFIG=Release`.

## Phase 3 — Settings plumbing

**`Vibe/Common/AppSettings.h`**, *above* the `#if TARGET_OS_OSX` line (shared, like `waveformStyle` — adding a property means choosing a side, `Common/CLAUDE.md`):

```objc
#define SETTINGS_VALUE_WAVEFORM_THEME_WHITE      @"white"
#define SETTINGS_VALUE_WAVEFORM_THEME_ORANGE     @"orange"
#define SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART  @"album_art"
#define SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM     @"custom"
- (NSString *)waveformTheme;                       // normalized on read
- (void)setWaveformTheme:(NSString *)identifier;
- (nullable VibeColor *)waveformCustomPlayedColor; // nil when unset/unparsable
- (void)setWaveformCustomPlayedColor:(nullable VibeColor *)color;
- (nullable VibeColor *)waveformCustomUnplayedColor;
- (void)setWaveformCustomUnplayedColor:(nullable VibeColor *)color;
```

- Keys: `Settings.waveformTheme`, `Settings.waveformCustomPlayedColor`, `Settings.waveformCustomUnplayedColor` — permanent once shipped (`Common/CLAUDE.md` trap: a stored key never follows a rename).
- Register `white` as the default in the shared `registerDefaults` dictionary (`AppSettings.m:131-138`).
- Colors persist as `#RRGGBB` hex strings — inspectable, cross-platform, `defaults write`-able. The hex↔`VibeColor` conversion goes in a category (behavior on a foreign class is a category, root `CLAUDE.md`) — but `VibeColor` is an alias, so follow the `PlatformImage.h` precedent instead: free functions `VibeColorFromHexString(NSString *)` / `VibeHexStringFromColor(VibeColor *)` in `Vibe/Common/` (the constructed class differs per platform, the documented exception). Parse defensively; garbage → nil.
- Theme identifier normalize-on-read: add `VibeNormalizedWaveformTheme(NSString *_Nullable)` to `SettingsRules.h` (pattern: `VibeNormalizedPitchRange`, `SettingsRules.h:8`), snapping unknowns to `white`. Getter calls it.
- **Migration** (decision above): in `AppSettings` init beside `migrateLegacyWaveformStyle` (`AppSettings.m:168-175`): if no `Settings.waveformTheme` key is stored (check `objectForKey:`, not the registered default) and the stored style is `sonic_cirrus`, write `orange`. Run once by nature — after it a key always exists.

**Tests**: `SettingsRulesTests` for the normalize; new tests for hex round-trip, bad-input nil, and the migration decision if it is factored as a pure rule (recommended: `static inline NSString *VibeMigratedWaveformTheme(NSString *storedTheme, NSString *storedStyle)` in `SettingsRules.h`).

**Acceptance**: `make test`, `make check-vocabulary`, `make build-ios`.

## Phase 4 — macOS Settings UI and live apply

**Live-apply hook** on `MainPlayerController` (pattern: `applyWaveformStyle:`, `MainPlayerController+Menus.m:212`):

```objc
- (void)applyWaveformTheme:(NSString *)identifier;  // persists, resolves, pushes to the view, full repaint
- (void)refreshWaveformTheme;                       // re-resolve without rewriting (custom color edited, artwork color landed)
```

**`SettingsAppearanceViewController.m`**:

- Theme popup row under the Waveform style row, identifiers on `representedObject` (pattern at lines 46-56), action calling `applyWaveformTheme:`.
- Two `NSColorWell`s in a row that is hidden unless the theme is `custom` (build the row always, toggle `hidden` — the grid row API supports it; adjust `kAppearancePaneHeight`). Color-well action writes the hex setting and calls `refreshWaveformTheme`. Set `colorWell.supportsAlpha = NO` — alpha is the renderers' business.
- `refreshFromSettings` re-selects the popup (normalized getter) and reloads the wells.
- **The settings walker doesn't model a color well**: `dump_settings_ui` will report it as the generic `control` kind and `settings_click` will refuse it (`Mac/Settings/CLAUDE.md` — anything a pane gains shows up there first). Extend the walker in `Vibe/Debug/`'s mac command table with a `colorwell` kind (value = hex string) — small, and it makes Phase 7 automatable; otherwise verification writes the defaults key directly and calls `refreshWaveformTheme` via a debug verb.

**Strings** (`vibe-strings` skill first): row labels and the four theme names in `VibeStrings.h` (`settings.waveform_theme.*`), `make strings`, translations for every catalog language, `make check-strings` + `make check-translations`.

**Acceptance**: `settings_click "Waveform theme" orange` flips the popup and the window repaints live; `dump_state` settings block shows the identifier; custom wells round-trip a color through quit/relaunch.

## Phase 5 — Album art wiring (macOS)

- `ArtworkDisplayController` already computes/memoizes the dominant color per artwork (`ArtworkDisplayController.m:252-271`). Surface it to `MainPlayerController` (it already coordinates artwork display) and forward into `refreshWaveformTheme` when it changes.
- **Async deliveries race track changes** (root `CLAUDE.md` guarantee): the dominant color is computed off-main from the display art; before applying, match the delivery against the current track exactly as the artwork delivery itself is matched. A stale color must never restyle the new track's waveform.
- Track with no art → the resolver passes nil → `WaveformTheme` falls back to White (Phase 1). Track change while theme is `album_art` re-resolves on every art settle, including the nil settle.
- Tune the Phase 1 legibility clamp here against real covers: near-black covers in light mode, near-white in dark, grayscale, and a highly saturated one; screenshot matrix via `vibe-debug`.

**Acceptance**: skip rapidly through a playlist mixing art/no-art files (the `vibe-stress` torture playlist is convenient) and confirm via screenshots that the waveform color always matches the *settled* track's art with no flicker-through of a stale color.

## Phase 6 — iOS

- Add the theme row to `Vibe/iOS/SettingsViewController.m` beside the style list (pattern at lines 48-84 and 279): White / Orange / Custom — **omit Album art** until an iOS dominant-color extraction exists (`dominantColor` is `Util/Mac`; the port is a `UIImage` counterpart or a shared `VibeImage` free function in `Util/`, deliberately out of scope here).
- Custom on iOS: `UIColorWell` (iOS 14+, floor is 26 — no guard needed), writing the same hex keys.
- `WaveformScrubberView` must rebuild on theme change exactly as it does on appearance change (`WaveformScrubberView.mm:1097-1110`): re-resolve the theme, `updateColors:`, and **invalidate the settled envelope bitmap** — the bake carries the old palette. Follow how `syncWaveformStyle` (`PlayerViewController.m:125`, `+Pager.m:150`) propagates a style change across the pager's pages and do the same for the theme.
- `make build-ios` is CI's AppKit-leak catch; everything shared added in Phases 1-3 must already pass it.

**Acceptance**: `launch-ios.sh` + `debug-ios.sh` screenshots of the scrubber under each theme, light and dark, settled (bitmap path) and mid-morph (live path) — the two must be indistinguishable per the pixel-identity guarantee.

## Phase 7 — Final verification

- Full matrix screenshots: {styles} × {white, orange, album art, custom} × {light, dark} on macOS; {styles} × {white, orange, custom} × {light, dark} on iOS.
- Hover visible in every cell of that matrix (the Phase 1 contrast rule's real test), including a custom near-white played color.
- Migration: seed defaults with `waveformStyle = sonic_cirrus` and no theme key, launch, assert theme reads `orange`; seed with an explicit `white`, assert it stays `white`.
- `make test`, `make analyze CONFIG=Release`, `make check-layout`, `make check-vocabulary`, `make check-strings`, `make check-translations`, `make build-ios`.

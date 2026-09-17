# Waveform rendering

The *rendering* half of the waveform system; the data — generation, caching, BPM and key — is `Audio/Waveform/` and `Audio/Analysis/`. This level holds what both views resolve before they draw. **`Renderers/` (the strategies, the morph engine, the level mapping), `Mac/` (the `NSView`) and `iOS/` (the scrubber) each carry their own `CLAUDE.md`.**

Everything here compiles into both targets, so it is AppKit- and UIKit-free apart from the `VibeColor` alias. `WaveformZoomMath.h` is the iOS scrubber's zoom floor, shared because it is arithmetic with no UIKit in it (`iOS/CLAUDE.md`).

## The theme

Root `CLAUDE.md` carries the guarantee — the theme beats the style's palette, each view resolves it and re-resolves on an appearance flip, `album_art` rides the artwork install path. This directory's half:

**`WaveformTheme.themeForIdentifier:isDark:artworkColor:customPlayed:customUnplayed:` is the only home of the identifier-to-colors rules.** Identifier, appearance, artwork color and the custom pair *for this appearance* go in; `playedColor`/`unplayedColor`/`hoverColor` come out. The identifier's source differs per platform — macOS reads it and the custom pair off `AppSettings.currentTheme`, iOS off the loose `AppSettings.waveformTheme` accessors — and the rules do not.

**Each color carries its side's resting level in its alpha; renderers own only their ramp shapes**, scaling every stop relative to that level (`VibeColorWithScaledAlpha`, `Common/PlatformColor.h`). The alphas are the levels that used to be renderer constants (`WaveformTheme.m` names them), which is what keeps Mono color-identical to the pre-theme look and Orange on Sonic Cirrus to the pre-theme Sonic Cirrus; a custom well's alpha dials its side's whole intensity and persists in the hex (`#RRGGBBAA`). A renderer that hard-codes an alpha breaks every theme at once.

**`flatFill` drops the ramp, never the level.** macOS sets it from `AppTheme.waveformGradient`; iOS never sets it. **The record-to-palette mapping on macOS is `themeForAppTheme:isDark:artworkColor:`**, guarded `TARGET_OS_OSX` because `AppTheme` is Mac-only: the player view and the settings preview both call it, so a new waveform field is mapped once.

**The album-art clamp tests perceptual luminance, not HSB brightness**, which is hue-blind and passes a too-dark pure blue; it blends toward the appearance's contrast pole, then desaturates toward the color's own luminance gray so the clamp still holds. The hover color derives from the played hue by the same luminance test, so the highlight survives any custom palette. `WaveformThemeTests` pins both.

## The loading indicator

The control is `Controls/LoadingIndicator`, and its traps are `Controls/CLAUDE.md`'s. **Each view owns only *when* it shows and *how wide*** — the mac view hands it the whole width (`Mac/CLAUDE.md`), the iOS scrubber the span its content occupies (`iOS/CLAUDE.md`).

**The fill eases to each reported fraction over roughly the previous gap, and never runs past what was reported.** `DownloadProgressMonitor` (`System/`) samples about once a second, the provider's ceiling: snapping would stutter, and running ahead would hide a stall. `set_loading` on the debug channel drives both modes without a download.

## Accessibility

**Both views are sliders** — `NSAccessibilitySliderRole`, `UIAccessibilityTraitAdjustable` — labelled `STR_A11Y_WAVEFORM`, because the waveform is the only pointer or touch seek and there is no other control to fall back to. Three things are shared and deliberate:

- **The step is 5% of the track (`kWaveformAccessibilityStep`), not seconds.** Each view is handed a 0–1 progress and reports a 0–1 seek; neither knows the duration.
- **An adjustment reports the seek and waits for the position to come back** through the owner's normal progress write, as a click or a released scrub does. Writing local progress shows a playhead that has not moved and then fights the next tick.
- **The value is `Formatters.percentString:`**, since VoiceOver reads a bare 0.5 as "zero point five".

Neither view is adjustable with nothing loaded (`scrubbingEnabled` on iOS; the mac increment returns NO). The iOS `accessibilityIdentifier` names the element for the XCUITest driver's pinch and is independent of all of this.

## ObjC++ boundary

The renderers and views are `.mm` for the C++ sample vectors. **Keep C++ types out of any header a plain ObjC `.m` imports**: `WaveformTheme.h` and `WaveformZoomMath.h` are the ObjC-safe headers here; `Renderers/AudioWaveformRenderer.h` and `Renderers/WaveformMorphEngine.h` bring in `AudioWaveform.h` and `<vector>`, so only `.mm` files may import them.

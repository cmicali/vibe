# Waveform rendering

The *rendering* half of the waveform system; the data — decoding, caching, BPM and key — is `Audio/Waveform/` and `Audio/Analysis/`. This level holds what both views resolve before they draw. **`Renderers/` (the strategies, the morph engine, the level mapping), `Mac/` (the `NSView`) and `iOS/` (the scrubber) each carry their own `AGENTS.md`.**

Everything here compiles into both targets, so it is AppKit- and UIKit-free apart from the `VibeColor` alias. `WaveformZoomMath.h` is the iOS scrubber's zoom floor, shared because it is arithmetic with no UIKit in it (`iOS/AGENTS.md`).

## The theme

Root `AGENTS.md` carries the guarantee — the theme beats the style's palette, each view resolves it and re-resolves on an appearance flip, `album_art` rides the artwork install path. This directory's half:

**`WaveformTheme.themeForIdentifier:isDark:artworkColor:customPlayed:customUnplayed:` is the only home of the identifier-to-colors rules.** Identifier, appearance, artwork color and the custom pair *for this appearance* go in; `playedColor`/`unplayedColor`/`hoverColor` come out. The identifier's source differs per platform — macOS reads it and the custom pair off `AppSettings.currentTheme`, iOS off the loose `AppSettings.waveformTheme` accessors — and the rules do not. Each platform maps its store in one method: `themeForAppTheme:isDark:artworkColor:` on macOS, `themeForSettings:isDark:artworkColor:` on iOS.

**Each color carries its side's resting level in its alpha; renderers own only their ramp shapes**, scaling every stop relative to that level (`VibeColorWithScaledAlpha`, `Common/PlatformColor.h`). `WaveformTheme.m` names the built-in levels; a custom well's alpha dials its side's whole intensity and persists in the hex (`#RRGGBBAA`). A renderer that hard-codes an alpha breaks every theme at once. **3-Band's fills are the theme's `bandColors`, opaque and outside that rule**, since its layers stack: seven colors from the three bands by one rule, shaded as a CDJ draws them or, with `AppTheme.waveformShadeOverlaps` off, each band painted plainly over the ones below as Engine DJ does. Rekord Bin's bands are the default on both platforms; the CDJ palette they come from follows the shaded rule within 13/255 (`WaveformThemeTests`). **iOS picks its bands from `AppSettings.waveformBandTheme`**: Rekord Bin, Dengine or Custom, resolved by `bandColorsForIdentifier:isDark:customBands:`. The setting is apart from `waveformTheme`, so a style switch keeps both. Dengine's dark bands are the mac's `dengine` theme, and `WaveformThemeTests` holds both built-in palettes to the mac's themes. Custom is shaded, and an unset band draws Rekord Bin's. Under 3-Band the mac's played side is Mono's, since the editor hides the waveform color its hover and the volume bar would otherwise read.

**`flatFill` drops the ramp, never the level.** macOS sets it from `AppTheme.waveformGradient`; iOS never sets it. **The record-to-palette mapping on macOS is `themeForAppTheme:isDark:artworkColor:`**, guarded `TARGET_OS_OSX` because `AppTheme` is Mac-only: the player view and the settings preview both call it, so a new waveform field is mapped once.

**`playheadColor` is the playhead line, and nil is its absence.** Nil, the played/unplayed boundary is the playhead, as every style was designed; non-nil, the whole waveform draws as played and a solid line in that color, the height of the seek band, marks the position. **No renderer reads it**: each view hands its renderer a progress of 1 and draws the line itself (`VibePlayheadLineRect`, `Renderers/AudioWaveformRenderer.h`), because the two place it differently — the mac's moves across the waveform, the scrubber's stays at center while the content moves. macOS sets it from `AppTheme.waveformPlayheadLine` and the `kVibeThemeColorWaveformPlayhead` pair (`Common/Mac/Theme/AGENTS.md`). iOS sets it from the loose `AppSettings.waveformPlayheadLine`, which is nil until chosen: `WaveformRendererRegistry.drawsPlayheadLineForIdentifier:chosen:` then answers the style's default, the line for 3-Band alone, in the appearance's contrast pole (no well there). The widget's two bakes never set it.

**The album-art clamp tests perceptual luminance, not HSB brightness**, which is hue-blind and passes a too-dark pure blue; it blends toward the appearance's contrast pole, then desaturates toward the color's own luminance gray so the clamp still holds. The hover color derives from the played hue by the same luminance test, so the highlight survives any custom palette. `WaveformThemeTests` pins both.

## The loading indicator

The control is `Controls/LoadingIndicator`, and its traps are `Controls/AGENTS.md`'s. **Each view owns only *when* it shows and *how wide*** — the mac view hands it the whole width (`Mac/AGENTS.md`), the iOS scrubber the span its content occupies (`iOS/AGENTS.md`).

**The fill eases to each reported fraction over roughly the previous gap, and never runs past what was reported.** The fraction is `CloudTransferRegistry`'s, which its monitor (`Loading/`) samples about once a second, the provider's ceiling: snapping would stutter, and running ahead would hide a stall. `set_loading` on the debug channel drives both modes without a download.

## Accessibility

**Both views are sliders** — `NSAccessibilitySliderRole`, `UIAccessibilityTraitAdjustable` — labelled `STR_A11Y_WAVEFORM`, because the waveform is the only pointer or touch seek and there is no other control to fall back to. Three things are shared and deliberate:

- **The step is 5% of the track (`kWaveformAccessibilityStep`), not seconds.** Each view is handed a 0–1 progress and reports a 0–1 seek; neither knows the duration.
- **An adjustment reports the seek and waits for the position to come back** through the owner's normal progress write, as a click or a released scrub does. Writing local progress shows a playhead that has not moved and then fights the next tick.
- **The value is `Formatters.percentString:`**, since VoiceOver reads a bare 0.5 as "zero point five".

Neither view is adjustable with nothing loaded (`scrubbingEnabled` on iOS; the mac increment returns NO). The iOS `accessibilityIdentifier` names the element for the XCUITest driver's pinch and is independent of all of this.

## ObjC++ boundary

The renderers and views are `.mm` for the C++ sample vectors. **Keep C++ types out of any header a plain ObjC `.m` imports**: `WaveformTheme.h` and `WaveformZoomMath.h` are the ObjC-safe headers here; `Renderers/AudioWaveformRenderer.h` and `Renderers/WaveformMorphEngine.h` bring in `AudioWaveform.h` and `<vector>`, so only `.mm` files may import them.

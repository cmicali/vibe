# Waveform rendering

The *rendering* half of the waveform system. The data, its decoding and caching, is `Audio/Waveform/`, and tempo and key are `Audio/Analysis/`. This level holds what both views resolve before they draw. **`Renderers/` (the strategies, the morph engine, the level mapping), `Mac/` (the `NSView`) and `iOS/` (the scrubber) each have their own `AGENTS.md`.**

Everything here compiles into both targets, so it is AppKit- and UIKit-free apart from the `VibeColor` alias. `WaveformZoomMath.h` is the iOS scrubber's zoom floor. It is shared only because it is plain arithmetic (`iOS/AGENTS.md`).

## The theme

The root `AGENTS.md` guarantee says the theme beats the style's palette, each view resolves it, and `album_art` rides the artwork install path. This directory's half follows.

**`WaveformTheme`'s `themeForIdentifier:isDark:artworkColor:customPlayed:customUnplayed:` is the only home of the identifier-to-colors rules.** It returns `playedColor`, `unplayedColor` and `hoverColor`. Each platform maps its store through one method. macOS uses `themeForAppTheme:isDark:artworkColor:`, which reads `AppSettings.currentTheme`'s record and is guarded `TARGET_OS_OSX`. The player view and the settings preview both call it, so a new waveform field is mapped once. iOS uses `themeForSettings:isDark:artworkColor:`, which reads the loose `waveformTheme` keys.

**Each color carries its side's resting level in its alpha. Renderers own only their ramp shapes**, and scale every stop against that level (`VibeColorWithScaledAlpha`, `Common/PlatformColor.h`). `WaveformTheme.m` names the built-in levels. A custom well's alpha sets its side's whole intensity and persists in the hex (`#RRGGBBAA`). A renderer that hard-codes an alpha breaks every theme at once.

**`flatFill` drops the ramp, never the level.** macOS sets it from the theme's `waveformGradient`. iOS never sets it. Spectrum and the pill draw no ramp either way (`WaveformRendererRegistry.supportsGradientForIdentifier:`), and the mac editor dims the switch for them.

**3-Band's fills are the theme's `bandColors`. They are opaque and outside the alpha rule**, since 3-Band's layers stack. Seven colors come from the three bands by one rule in `WaveformTheme.m`. Shaded, they follow a CDJ. With the theme's `waveformShadeOverlaps` off, each band paints plainly over the ones below, as Engine DJ does. Rekord Bin's bands are the default on both platforms. On macOS, under 3-Band and Spectrum the played side is Mono's, because the hover and the volume bar read it and the editor hides the waveform color. **iOS picks its bands from `waveformBandTheme`**: Rekord Bin, Dengine or Custom, resolved by `bandColorsForIdentifier:isDark:customBands:`. That key is separate from `waveformTheme`, so a style switch keeps both. Custom is shaded, and an unset band draws Rekord Bin's. `WaveformThemeTests` holds the built-in palettes to the CDJ's colors and to the mac's `dengine` theme.

**Spectrum's primaries are the theme's `spectrumColors`. They are opaque and outside the alpha rule too.** They come from Spectrum's palette, resolved by `spectrumColorsForIdentifier:isDark:customBands:`: RGB (the default), Blue, Green or Custom. RGB is red, green and blue for the low, mid and high bands, close in lightness. Blue is the CDJ's blue waveform, from deep blue lows to near-white highs. Green is the same ramp in green. Each built-in light set is darker, so it reads on white. Custom is the band wells as they are, the same wells 3-Band's Custom reads. The mac reads the palette off the theme's `waveformSpectrumPalette`, iOS off `AppSettings.waveformSpectrumPalette`.

**`playheadColor` is the playhead line, and nil means no line.** With nil, the played and unplayed boundary is the playhead. With a color, the whole waveform draws as played and a solid line the height of the seek band marks the position. **No renderer reads it.** Each view hands its renderer a progress of 1 and draws the line itself (`VibePlayheadLineRect`, `Renderers/WaveformBarMath.h`). The mac's line moves across the waveform. The scrubber's stays at center while the content moves. macOS sets it from the theme's `waveformPlayheadLine` and the `kVibeThemeColorWaveformPlayhead` pair (`Common/Mac/Theme/AGENTS.md`). iOS sets it from `AppSettings.waveformPlayheadLine`, which is nil until chosen. While nil, `WaveformRendererRegistry`'s `drawsPlayheadLineForIdentifier:chosen:` answers the style's default, which is the line for 3-Band and Spectrum. The iOS line is the appearance's contrast pole. The widget's bakes never set it.

**The album-art clamp tests perceptual luminance, not HSB brightness.** HSB brightness is hue-blind and passes a too-dark pure blue. The clamp blends toward the appearance's contrast pole. The unplayed side is then desaturated toward the color's own luminance gray, which keeps the clamp intact. The hover color comes from the played color by the same luminance test, so the highlight survives any custom palette. `WaveformThemeTests` pins both.

## The loading indicator

The control is `Controls/LoadingIndicator`, and its traps are in `Controls/AGENTS.md`. **Each view owns only when it shows and how wide.** The mac view hands it the whole width. The iOS scrubber hands it the span its content occupies (`iOS/AGENTS.md`).

**The fill eases to each reported fraction and never runs past it.** The fraction is `CloudTransferRegistry`'s, which its monitor (`Loading/Transfer/`) samples about once a second. Snapping would stutter, and running ahead would hide a stall. Each ease takes half the previous gap, capped, then holds. `set_loading` on the mac's debug channel drives both modes without a download.

## Accessibility

**Both views are sliders** (`NSAccessibilitySliderRole`, `UIAccessibilityTraitAdjustable`), labelled `STR_A11Y_WAVEFORM`. The waveform is the only pointer or touch seek, so there is no other control to fall back to.

- **The step is 5% of the track (`kWaveformAccessibilityStep`), not seconds.** Each view knows a 0 to 1 progress and reports a 0 to 1 seek, never the duration.
- **An adjustment reports the seek and waits for the position to come back** through the owner's normal progress write. Writing local progress would show a playhead that has not moved, and it would fight the next tick.
- **The value is `Formatters`' `percentString:`**, since VoiceOver reads a bare 0.5 as "zero point five".

Neither view is adjustable with nothing loaded. The iOS `accessibilityIdentifier` names the element for the XCUITest driver's pinch (`Tests/iOSDriver/`) and is unrelated to the above.

## ObjC++ boundary

The renderers and views are `.mm` for the C++ sample vectors. **Keep C++ types out of any header a plain ObjC `.m` imports.** `WaveformTheme.h`, `WaveformZoomMath.h` and the renderers' two math headers are safe here. `Renderers/WaveformRenderer.h` and `Renderers/WaveformMorphEngine.h` bring in `AudioWaveform.h` and `<vector>`, so only `.mm` files may import them.

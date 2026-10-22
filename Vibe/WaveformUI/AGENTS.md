# Waveform rendering

The *rendering* half of the waveform system. The data is vibe-libs' `waveform/Waveform`, its decoding and caching are `waveform/WaveformLoading`, and tempo and key are `audio/Analysis`. **The styles are vibe-libs' `waveform/WaveformStyles`**: the renderers, the registry, the morph engine, the level and bar math, the theme, and the zoom math. Its `AGENTS.md` is the authority for how each style draws and for the theme's rules. This directory holds the views that host a renderer, and what Vibe maps onto the theme. **`Mac/` (the `NSView`) and `iOS/` (the scrubber) each have their own `AGENTS.md`.**

`WaveformAccessibility.h` is the one shared file here. The platform views live under `Mac/` and `iOS/`.

## The theme

The root `AGENTS.md` guarantee says the theme beats the style's palette, each view resolves it, and `album_art` rides the artwork install path. vibe-libs' `waveform/WaveformStyles/AGENTS.md` holds the theme's own rules: the identifier-to-colors resolution, the alpha rule, `flatFill`, the band and Spectrum palettes, `playheadColor`, and the album-art clamp. Vibe's half follows.

**Each platform maps its store through one method of `Common/WaveformTheme+Settings`, Vibe's category, so the theme itself reads no store.** macOS uses `themeForAppTheme:isDark:artworkColor:`, which reads `AppSettings.currentTheme`'s record and is guarded `TARGET_OS_OSX`. The shell's `themeProvider` block and the settings preview both call it, so a new waveform field is mapped once. The mac view resolves only through that block (`WaveformThemeProvider`, `WaveformTheme.h`), with the appearance it draws in and the artwork color settled on it. iOS uses `themeForSettings:widget:isDark:artworkColor:`. It reads the card’s settings or the widget’s copies. The scrubber, too, resolves only through its shell's `themeProvider` block. The mac's band wells go through `bandColorsForWells:shaded:isDark:`, the one rule from three bands to seven fills. `Tests/Common/WaveformThemeSettingsTests.m` pins the mac's mapping.

**`flatFill` is the mac's alone.** macOS sets it from the theme's `waveformGradient`. iOS never sets it. The mac editor dims the switch for Spectrum and the pill, which draw no ramp either way.

**3-Band's bands.** On macOS the theme's `waveformShadeOverlaps` chooses shaded or plain overlaps. Rekord Bin's bands are the default on both platforms. On macOS, under 3-Band and Spectrum the played side is Mono's, because the hover and the volume bar read it and the editor hides the waveform color. **iOS picks its bands from `waveformBandTheme`**: Rekord Bin, Dengine or Custom. That key is separate from `waveformTheme`, so a style switch keeps both. `WaveformThemeSettingsTests` holds iOS's band palettes to the mac's built-in `rekord_bin` and `dengine` themes.

**Spectrum's palette and coloring.** Blue's dark set is the Kinda Blue theme's own colors. The mac reads the palette off the theme's `waveformSpectrumPalette`, iOS off `AppSettings.waveformSpectrumPaletteForWidget:`. The mac reads the coloring off the theme's `waveformSpectrumColoring`, iOS off `AppSettings.waveformSpectrumColoringForWidget:`. By section is Vibe's default. A bare `WaveformTheme` draws Precise, but every resolver here sets it.

**The playhead line.** The mac's line moves across the waveform. The scrubber's stays at center while the content moves. macOS sets `playheadColor` from the theme's `waveformPlayheadLine` and the `kVibeThemeColorWaveformPlayhead` pair (`Common/Mac/Theme/AGENTS.md`). The iOS shell pushes the scrubber `drawsPlayheadLine`, from `AppSettings.waveformPlayheadLineForWidget:`, which is nil until chosen. While nil, the registry's `drawsPlayheadLineForIdentifier:chosen:` answers the style's default. The iOS line is the appearance's contrast pole at 68% opacity, and it reaches 8 pt past the seek band at each end. The mac's unset pair is 80%. The widget's line is white at 68% opacity, as the card's is. It spans 87.5% of the strip's height, half way from the band to the strip's edges. The widget's bakes never set it: under a line they bake the whole strip as played, and the widget draws the line (`iOS/Widget/AGENTS.md`).

## The loading indicator

The control is `Controls/LoadingIndicator`, and its traps are in `Controls/AGENTS.md`. **Each view owns only when it shows and how wide.** The mac view hands it the whole width. The iOS scrubber hands it the span its content occupies (`iOS/AGENTS.md`).

**The fill eases to each reported fraction and never runs past it.** The fraction is `CloudTransferRegistry`'s, which its monitor (`vibe-libs/files/FileLoading/Transfer/`) samples about once a second. Snapping would stutter, and running ahead would hide a stall. Each ease takes half the previous gap, capped, then holds. `set_loading` on the mac's debug channel drives both modes without a download.

## Accessibility

**Both views are sliders** (`NSAccessibilitySliderRole`, `UIAccessibilityTraitAdjustable`). The waveform is the only pointer or touch seek, so there is no other control to fall back to. Each shell labels its view (`STR_A11Y_WAVEFORM`) where it builds it, so the views read no strings. The step and the spoken value are `WaveformAccessibility.h`, shared by both views.

- **The step is 5% of the track (`kWaveformAccessibilityStep`), not seconds.** Each view knows a 0 to 1 progress and reports a 0 to 1 seek, never the duration.
- **An adjustment reports the seek and waits for the position to come back** through the owner's normal progress write. Writing local progress would show a playhead that has not moved, and it would fight the next tick.
- **The value is a whole percentage** (`VibeWaveformAccessibilityValue`), since VoiceOver reads a bare 0.5 as "zero point five".

Neither view is adjustable with nothing loaded. The iOS `accessibilityIdentifier` names the element for the XCUITest driver's pinch (`Tests/iOSDriver/`) and is unrelated to the above.

## ObjC++ boundary

The views are `.mm` for the C++ sample vectors. **Keep C++ types out of any header a plain ObjC `.m` imports.** `WaveformAccessibility.h` is safe, as are the styles' `WaveformTheme.h`, `WaveformZoomMath.h`, `WaveformRendererRegistry.h`, and two math headers. The styles' `WaveformRenderer.h` and `WaveformMorphEngine.h` bring in `AudioWaveform.h` and `<vector>`, so only `.mm` files may import them.

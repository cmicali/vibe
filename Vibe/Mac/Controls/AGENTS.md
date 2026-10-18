# Custom-drawn controls (macOS)

AppKit controls drawn with CALayers or in `drawRect:`. A control belongs here when it is genuinely AppKit: it has hover and press states a touch control lacks, or it is an `NSControl` subclass. **A control both apps draw the *same* way goes in the shared `Vibe/Controls/` instead**, such as `EqualizerIndicatorView`.

## SymbolButton

A borderless momentary push button (`NSControl`) that draws an SF Symbol. It rasterizes the symbol at the backing scale into a CALayer **mask** over a flat color layer. CALayer cannot tint its contents, and the mask keeps hover, press and disabled transitions as animatable color fades on the render server.

It fades to its highlight color on hover, dims to half that while pressed, tracks a drag off and back, sends its action on mouse-up inside, and lets clicks through when disabled. Swapping `symbolName` redraws at once with no fade. Each button sets its own `symbolPointSize`, and the icon draws centered in the frame. The 50pt transport hit targets carry symbols configured at 31pt, whose glyphs draw at about 0.8 times that.

**The state colors keep one relationship**: the factory ratios of the resting alpha (0.55) to hover (0.8), pressed (half of hover) and disabled (0.19). `setSymbolColorsFromRestingColor:` derives all of them from one picked color, alpha included, so a theme dresses a button with one color well. **A custom `image` replaces the symbol.** A second layer draws the picture in its own colors, aspect-fit into the box a glyph of the configured size fills. The same states fade its opacity by the same ratios, over full strength at hover. While an image is set, the symbol and colors are ignored. nil returns to the mask.

## Drawn controls

`DrawnControls.h` holds controls drawn in `drawRect:` in place of AppKit's, to AppKit's measured metrics and colors. They draw gray while the window is not key and at half alpha when disabled.

**TRAP: use custom drawing to avoid AppKit's SwiftUI control hosts and their Metal startup cost on macOS 26.** A slider subclass that draws itself stays unhosted. `VibeDetentSlider` uses that path. Check `dump_view_tree` for `_NSCoreHostingView` before changing a control.

- **`VibeSlider`** is the main window's volume slider: 0 to 1, the fill `trackFillColor` or the system accent, and a VoiceOver slider stepping 5%. It sends its action from the mouse-down, every moving drag and, always, the mouse-up, each from its own event handler. So `NSApp.currentEvent` tells the volume control's drag hold which it was (`MainWindow/LAYOUT.md`). `moveBySteps:` moves it by whole or fractional 5% steps and sends the action when it moved.
- **`VibeSwitch`** is every Settings switch (`switchWithAction:`). It matches the small `NSSwitch`, with its slide, Space under full keyboard access, and a VoiceOver checkbox of the switch subrole. Setting `state` neither slides nor sends the action.
- **`VibeDetentSlider`** is the Settings slider with a detent, in a file of its own. The theme editor's corner radius, symbol size, bar density and bar width sliders use it. So does Appearance's waveform gain. It draws ticks above and below the track at `detentValue`, where its action snaps.

## Image views

- **`CrossfadingImageView`** is `ArtworkImageView`'s layer-backed `NSImageView` base. `setImage:` cross-fades the new image over the old. It vends `kVibeArtCrossfadeDuration`, **shared with the header tint wash, so art and tint fade on one clock** (`MainWindow/LAYOUT.md`). The new image sits beneath outgoing fade layers. At most two outgoing layers remain. A third drops the oldest. An in-flight fade never resets to opaque. It is opted out of drag and drop, so file drops fall through to the window.
- **`ArtworkImageView`** adds `NSDraggingSource` for the foreground art card. A drag out carries whatever `AppSettings.artworkDragAction` names: the file itself (`copy_file`, the default), its path, or the track's `trackDisplayName`. The mode is read **once at drag start**. Only the file payload holds the security scope open past `beginDragWithEvent:`, since only the file is read by the receiver after the drop. The text payloads leave `_securityScopedURL` nil, so the end-of-session stop stays balanced. `fileURL` alone says there is a track, and every mode gates on it. `ArtworkDisplayController` reassigns both payload properties together. A pending press re-checks its file and payload at the first drag event, because Close or a playback failure can clear them after mouse-down.
- **`ScaledImageView`** is an `NSImageView` with a `drawImageOverlayInRect:` hook for subclasses.

## Pitch control

- **`PitchFaderView`** is the fader, with its own delegate.
- **`PitchControlPanel`** is the panel around it and what the rest of the app talks to. **The fader inside is an implementation detail, so gestures report the *panel* as the sender.** It vends `kPitchPanelWidth`, the width the main window grows by on reveal (`MainWindow/AGENTS.md`).

Both delegates fire `…DidEndAdjusting:` **once** when a pitch gesture ends: on the mouse-up after a click or drag, on a double-click reset, or after an accessibility step. That is the hook for work too heavy for every drag tick. The per-tick callback is `didChangePitch:`.

**A click on the panel's title or readout reports `pitchControlPanelDidClickHeader:`, and the controller switches the range between 8% and 16%.** The labels pass clicks through to the panel. The panel refuses the window drag so that click is its own, and drags the window itself from everywhere else. The faded header of a collapsed playlist is not a target.

`VibeQuartzLockGreen(a)` is the green shared by the fader's zero LED and the panel's readout. It takes an alpha, so the LED glow can use a faint variant.

**The fader is an accessibility slider** (`NSAccessibilitySliderRole`, `STR_A11Y_PITCH_FADER`, the same signed reading the panel draws). It is a custom `NSView` with no control to inherit from, and without this pitch is unreachable with VoiceOver. Its step is **0.5%, not the 0.1% a drag quantizes to.** Stepping at 0.1% would take 160 presses to cross the range. Half a percent divides both ranges (8 and 16) evenly, so stepping always lands back on exactly 0. An adjustment goes through `userSetPitch:`, so it gets the detent, the rounding and `didChangePitch:` a drag gets. It then fires `…DidEndAdjusting:`, since one press is the whole gesture.

# Custom-drawn controls (macOS)

AppKit controls drawn with CALayers or in `drawRect:`. A control belongs here when it is genuinely AppKit: it has hover and press states a touch control lacks, or it is an `NSControl` subclass. **A control both apps draw the *same* way is a shared file of vibe-libs' `ui/Controls`**, such as `EqualizerIndicatorView`. **A control that reads no setting, string, or type of Vibe's belongs in vibe-libs' `ui/Controls`.**

This directory holds `ArtworkImageView` and the pitch controls. The symbol button, the drawn slider and switch, the detent slider, `CrossfadingImageView`, `ScaledImageView`, and `VibeLinkLabel` are in vibe-libs' `ui/Controls`. Its `AGENTS.md` describes them. Read it before adding a control here. Its TRAP on AppKit's SwiftUI control hosts applies to every control in this directory too.

## How Vibe uses the vibe-libs controls

- **`SymbolButton`** draws the transport row and the traffic lights. The 50pt transport hit targets carry symbols configured at 31pt, whose glyphs draw at about 0.8 times that. A theme dresses a button with one color well, through `setSymbolColorsFromRestingColor:`.
- **`VibeSlider`** is the main window's volume slider. `VolumeControlView` installs its `accessibilityValueFormatter` over `Formatters.percentString:`. The slider sends its action from the mouse-down, from every drag that moves it, and always from the mouse-up. So `NSApp.currentEvent` tells the volume control's drag hold which one it was (`MainWindow/LAYOUT.md`).
- **`VibeSwitch`** is every Settings switch (`switchWithAction:`).
- **`VibeDetentSlider`** is the Settings slider with a detent. The theme editor's corner radius, symbol size, bar density, and bar width sliders use it. So does Appearance's waveform gain.
- **`CrossfadingImageView`** is `ArtworkImageView`'s base. Its `kVibeArtCrossfadeDuration` is **shared with the header tint wash, so art and tint fade on one clock** (`MainWindow/LAYOUT.md`).
- **`ScaledImageView`** is `PlaylistCoverImageView`'s base.

## ArtworkImageView

**`ArtworkImageView`** adds `NSDraggingSource` for the foreground art card. A drag out carries whatever `AppSettings.artworkDragAction` names: the file itself (`copy_file`, the default), its path, or the track's `trackDisplayName`. The mode is read **once at drag start**. Only the file payload holds the security scope open past `beginDragWithEvent:`, since only the file is read by the receiver after the drop. The text payloads leave `_securityScopedURL` nil, so the end-of-session stop stays balanced. `fileURL` alone says there is a track, and every mode gates on it. `ArtworkDisplayController` reassigns both payload properties together. A pending press re-checks its file and payload at the first drag event, because Close or a playback failure can clear them after mouse-down.

## Pitch control

- **`PitchFaderView`** is the fader, with its own delegate.
- **`PitchControlPanel`** is the panel around it and what the rest of the app talks to. **The fader inside is an implementation detail, so gestures report the *panel* as the sender.** It vends `kPitchPanelWidth`, the width the main window grows by on reveal (`MainWindow/AGENTS.md`).

Both delegates fire `…DidEndAdjusting:` **once** when a pitch gesture ends: on the mouse-up after a click or drag, on a double-click reset, or after an accessibility step. That is the hook for work too heavy for every drag tick. The per-tick callback is `didChangePitch:`.

**A click on the panel's title or readout reports `pitchControlPanelDidClickHeader:`, and the controller switches the range between 8% and 16%.** The labels pass clicks through to the panel. The panel refuses the window drag so that click is its own, and drags the window itself from everywhere else. The faded header of a collapsed playlist is not a target.

`VibeQuartzLockGreen(a)` is the green shared by the fader's zero LED and the panel's readout. It takes an alpha, so the LED glow can use a faint variant.

**The fader is an accessibility slider** (`NSAccessibilitySliderRole`, `STR_A11Y_PITCH_FADER`, the same signed reading the panel draws). It is a custom `NSView` with no control to inherit from, and without this pitch is unreachable with VoiceOver. Its step is **0.5%, not the 0.1% a drag quantizes to.** Stepping at 0.1% would take 160 presses to cross the range. Half a percent divides both ranges (8 and 16) evenly, so stepping always lands back on exactly 0. An adjustment goes through `userSetPitch:`, so it gets the detent, the rounding and `didChangePitch:` a drag gets. It then fires `…DidEndAdjusting:`, since one press is the whole gesture.

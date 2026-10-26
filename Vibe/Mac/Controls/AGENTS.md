# Custom-drawn controls (macOS)

AppKit controls drawn with CALayers or in `drawRect:`. A control belongs here when it is genuinely AppKit: it has hover and press states a touch control lacks, or it is an `NSControl` subclass. **A control both apps draw the *same* way is a shared file of vibe-libs' `ui/Controls`**, such as `EqualizerIndicatorView`. **A control that reads no setting, string, or type of Vibe's belongs in vibe-libs' `ui/Controls`.**

This directory holds `ArtworkImageView`. The symbol button, the drawn slider and switch, the detent slider, the pitch fader and its panel, `CrossfadingImageView`, `ScaledImageView`, and `VibeLinkLabel` are in vibe-libs' `ui/Controls`. Its `AGENTS.md` describes them. Read it before adding a control here. Its TRAP on AppKit's SwiftUI control hosts applies to every control in this directory too.

## How Vibe uses the vibe-libs controls

- **`SymbolButton`** draws the transport row and the traffic lights. The 50pt transport hit targets carry symbols configured at 31pt, whose glyphs draw at about 0.8 times that. A theme dresses a button with one color well, through `setSymbolColorsFromRestingColor:`.
- **`VibeSlider`** is the main window's volume slider. `VolumeControlView` installs its `accessibilityValueFormatter` over `Formatters.percentString:`. The slider sends its action from the mouse-down, from every drag that moves it, and always from the mouse-up. So `NSApp.currentEvent` tells the volume control's drag hold which one it was (`MainWindow/LAYOUT.md`).
- **`VibeSwitch`** is every Settings switch (`switchWithAction:`).
- **`VibeDetentSlider`** is the Settings slider with a detent. The theme editor's corner radius, symbol size, bar density, and bar width sliders use it. So does Appearance's waveform gain.
- **`CrossfadingImageView`** is `ArtworkImageView`'s base. Its `kVibeArtCrossfadeDuration` is **shared with the header tint wash, so art and tint fade on one clock** (`MainWindow/LAYOUT.md`).
- **`ScaledImageView`** is `PlaylistCoverImageView`'s base.
- **`PitchControlPanel`** is the pitch control on the main window's right edge. The window grows by `kPitchPanelWidth` to reveal it (`MainWindow/AGENTS.md`). `buildPitchPanel` (`MainPlayerController+Window`) pushes its title, `STR_LABEL_PITCH`, and the fader's VoiceOver label, `STR_A11Y_PITCH_FADER`. It pushes `Formatters.signedPercentString:` as the formatter of the readout and the spoken value. It pushes the theme's `resolvedWindowCornerRadius`, and `applyWindowChrome` pushes it again on every theme change. `applyPitchRange` sets the panel's range together with `AudioPlayer.maxPitch`, so the two stay in step. **A click on the panel's header switches the range between 8% and 16%.** A gesture's end publishes Now Playing once.

## ArtworkImageView

**`ArtworkImageView`** adds `NSDraggingSource` for the foreground art card. A drag out carries whatever `AppSettings.artworkDragAction` names: the file itself (`copy_file`, the default), its path, or the track's `trackDisplayName`. The mode is read **once at drag start**. Only the file payload holds the security scope open past `beginDragWithEvent:`, since only the file is read by the receiver after the drop. The text payloads leave `_securityScopedURL` nil, so the end-of-session stop stays balanced. `fileURL` alone says there is a track, and every mode gates on it. `ArtworkDisplayController` reassigns both payload properties together. A pending press re-checks its file and payload at the first drag event, because Close or a playback failure can clear them after mouse-down.

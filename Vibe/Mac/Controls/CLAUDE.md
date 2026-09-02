# Custom-drawn controls (macOS)

CALayer-drawn AppKit controls. A control belongs here when it is genuinely AppKit — hover and press states a touch control does not have, or an `NSControl` subclass. **A control both apps must draw the *same* one of goes in the shared `Vibe/Controls/` instead**, which is where `EqualizerIndicatorView` (the playing-row bars) lives, since the iOS library rows draw it too.

## SymbolButton

A borderless momentary push button (`NSControl`) drawing an SF Symbol. It rasterizes the symbol at the backing scale into a CALayer **mask** over a flat color layer — CALayer cannot tint its contents, and the mask is what keeps hover, press and disabled transitions as animatable color-property fades composited on the render server. No asset-catalog images are involved, so it stays resolution independent.

It fades to its highlight color on hover, dims to half that opacity while pressed, tracks a drag off and back, sends its action on mouse-up inside, and is click-through when disabled. Swapping `symbolName` redraws instantly with no fade.

Each button sets its own `symbolPointSize` and the icon is drawn centered in the frame, so the 50pt transport hit targets carry symbols configured at 31pt, whose glyphs draw at roughly 0.8 times that (~25pt).

## Image views

- **`CrossfadingImageView`** — `ArtworkImageView`'s layer-backed `NSImageView` base, so `setImage:` cross-fades the incoming image over the outgoing one. It vends `kVibeArtCrossfadeDuration`, **shared with the header tint wash so art and tint fade on the same clock** (`MainWindow/APPEARANCE.md`) — and it matches the tint's retargeting too: rapid successive images blend continuously, each outgoing image finishing its own fade beneath the newer ones, never snapping an in-flight fade back to opaque. It is opted out of drag-and-drop, so file drops fall through to the window.
- **`ArtworkImageView`** — `CrossfadingImageView` plus `NSDraggingSource`: the foreground art card, dragged out as whatever `AppSettings.artworkDragAction` names — the file itself (`copy_file`, the default), its path, or the displayed track's `trackDisplayName`. The mode is read **once at drag start**, and only the file payload holds the security scope open past `beginDragWithEvent:`, since only it is read by the receiver after the drop; the text payloads leave `_securityScopedURL` nil so the end-of-session stop stays balanced. `fileURL` alone is the have-a-track signal every mode gates on, and both payload properties are reassigned together by `ArtworkDisplayController`.
- **`ScaledImageView`** — an `NSImageView` with a `drawImageOverlayInRect:` hook for subclasses.

## Pitch control

- **`PitchFaderView`** — the fader itself, with its own delegate.
- **`PitchControlPanel`** — the panel around it, and what the rest of the app talks to. **The fader inside is an implementation detail, so gestures are reported with the *panel* as the sender.** It vends `kPitchPanelWidth`, the width the main window grows by when the panel is revealed — see `MainWindow/CLAUDE.md` for why the reveal is the one resize the two `contentView` siblings must not follow.

Both delegates fire `…DidEndAdjusting:` **once** when a pitch gesture ends — on the mouse-up after a click or drag, or on a double-click reset. That is the hook for work too heavy to run on every drag tick; the per-tick callback is the separate `didChangePitch:`.

`VibeQuartzLockGreen(a)` is the quartz-lock green shared by the fader's zero LED and the panel's readout, parameterized by alpha so the LED glow can use a low-alpha variant.

**The fader is an accessibility slider** (`NSAccessibilitySliderRole`, `STR_A11Y_PITCH_FADER`, the same signed reading the panel draws), because otherwise pitch is unreachable with VoiceOver — it is a custom-drawn `NSView` with no control underneath to inherit from. Its step is **0.5%, not the 0.1% a drag quantizes to**: a drag crosses the range in one movement while stepping at 0.1% would take 160 presses, and half a percent divides both ranges (8 and 16) evenly, so stepping always lands back on exactly 0 rather than skipping the centre detent. An adjustment goes through `userSetPitch:` so it carries the detent, the rounding and `didChangePitch:` that a drag does, then fires `…DidEndAdjusting:` — one press *is* the whole gesture.

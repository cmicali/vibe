# Main window: layout and chrome

Read this before changing layout numbers, the glass chrome, the art-tint/accent pipeline, or the codec line's rendering. Behavior — the controller, transport, the convert swap and undo, display states, window resize rules — is in `CLAUDE.md`.

## Layout

Programmatic layout: no nibs, absolute frames and autoresizing masks. Every number lives in one named layout block at the top of `MainPlayerContentView.m`. Frames are authored at the design size, `kMainWindowContentWidth` × `kMainWindowDesignHeight`; each subview's mask says how it stretches to the user's window size.

One frame clears content rather than geometry: the artist line ends where the codec line's *text* begins — right-aligned in a column sized for its worst case (a long codec string behind three FX symbols), which fully reserved would cost the artist line a third of its width at design size, nearly all of it narrow. `layoutArtistLineClearOfCodecLine` re-caps it against what actually renders, hooked from both moving inputs: geometry via `resizeSubviewsWithOldSize:` (covers live drags), text via `TrackDisplayController`'s compose. The layout block's frame is the worst-case reservation and the fallback. The title line only has to clear the shorter BPM line, which its shrink-to-fit width already does.

The header glass panel deliberately bleeds `kHeaderPanelRightBleed` past the window's right edge so the window shape clips its right-side corner arcs off-screen; without it the uniformly rounded glass shows visible curves instead of running square to the edge.

## Chrome: three layers of Liquid Glass

macOS 26 `NSGlassEffectView`, three layers. **Before macOS 26, where `NSGlassEffectView` does not exist, the two glass layers fall back to frosted behind-window `NSVisualEffectView`s** (`UnderWindowBackground`, `StateActive`, blur shaped by `frostCornerMaskWithRadius:` — an `NSVisualEffectView`'s blur region ignores a layer cornerRadius); both creation sites branch on `@available(macOS 26, *)`, the deployment target is 14.0, and any API newer than that floor needs its own guard (`-Wunguarded-availability` enforces this). The playlist frost is already an `NSVisualEffectView` and is identical on both:

**1. The backdrop.** A window-spanning glass backdrop behind everything, **Clear** style, installed in `buildContentInWindow:`.

**2. The header panel and its tint.** The header/waveform area gets a **Regular**-style glass panel in `MainPlayerContentView` (Regular is the default — no explicit `.style` to grep for). Over it, `headerTintView` is a passthrough layer view washed with the current track's dominant art color: `NSImage+Util`'s `dominantColor` uses a hue histogram weighted by saturation × brightness, falling back to average gray for monochrome art; `ArtworkDisplayController` applies it and also owns the art view, the dock icon and deferred art loads.

The wash's clamps are **perceptual, not HSB** (`NSColor+OKLCH`): HSB brightness is hue-blind, and an HSB cap let bright-hued art wash out the unplayed waveform. Lightness is capped at OKLCH L ≤ 0.30 in dark mode (over a light waveform) and ≥ 0.87 in light (over a dark one), chroma moderately in both; an out-of-gamut result gives up chroma, never lightness or hue. The same resolution emits the playlist accent through `accentColorDidChangeHandler`, in a text-legible band.

TRAP: `refreshHeaderTint` must resolve light/dark from the **window**, not `headerTintView`. Its caller is the *content view's* `viewDidChangeEffectiveAppearance`, and AppKit updates the tree top-down, so a subview there still reports the outgoing appearance — reading it left the wash a full appearance behind on every live toggle.

The wash is deliberately not the glass's own `tintColor`: AppKit silently discards a glass view's tint whenever the window is not key, with no public override — `isKeyWindow` overrides don't affect it, only the private `resignKeyAppearance` does (verified by pixel-diffing), and private API is off-limits. So the window stays as key-state-independent as public API allows: the tint wash and playlist frost (`NSVisualEffectStateActive`) never dim; the glass views' own subtle inactive dimming is accepted. Tint changes fade over `kVibeArtCrossfadeDuration`, shared with `CrossfadingImageView`'s art crossfade.

**3. The playlist frost.** A behind-window `NSVisualEffectView`, `UnderWindowBackground` in both appearances (the light `WindowBackground` material is effectively opaque paint), plus a brightening white wash in light mode only. Row text is not readable over Clear glass.

TRAP: an `NSGlassEffectView` inside `MainPlayerContentView` must not stretch from design height to window height: this frost band, as a height-sizable `NSGlassEffectView`, had its SwiftUI hosting internals fight the stretch and the window silently refused to expand — hence `NSVisualEffectView`, which also never dims (`NSVisualEffectStateActive`). The trap is the design-size-to-window-size autoresizing stretch, not height-flexibility itself: the backdrop is created full-bleed at live bounds, `NSViewHeightSizable`, and resizes cleanly. Width-flexibility is fine for both glass views.

All corner rounding shares `kMainWindowCornerRadius` (`MainWindowLayout.h`, 20pt, the macOS 27 standardized window radius): the contentView layer mask, both glass views, the header tint layer and the pitch panel's right-edge path.

## The codec line and FX indicators

The codec line doubles as the FX indicator: the SF Symbols of latched effects draw inline at the head of the same right-aligned run, glued to the codec text. Low kill shows the filled dial while its boost is on (the boost modifies that filter rather than being an effect of its own); reverb one symbol; each active delay one, matching the FX menu's. `AppSettings.showFileInfo` off empties the codec text and the BPM/key line at render time (`TrackDisplayController` reads it in `renderState:` and `renderBPM:`), but the FX symbols are deck state, not file info, and keep composing.

Two adjustments are optical, not derivable from any metric: symbols draw at bold weight (the default stroke is a hairline at this size), and the two dial glyphs get their own size multiplier — they spend much of their bounding box on tick marks and read visibly smaller at the row's shared box height.

The BPM line below carries the key after a `|` separator, the same one the codec line uses between its fields, and with `AppSettings.keyColorsEnabled` on that key run alone is redrawn bold and in its Camelot color — one hue per wheel number, anchored so 1 is green as on the printed wheel, so harmonically compatible keys sit in neighboring hues and a relative major/minor pair shares one. The palette is a `dynamicProvider` color per number (`camelotColor` in `TrackDisplayController.m`), less saturated on dark chrome and darker on light, since a single fixed hue cannot read on both, and neither at full brightness — that reads as garish beside the dimmed corner text. It approximates the published wheel rather than sampling it. TRAP: the BPM line's change guard cannot be the string alone, because toggling the color setting leaves the text identical while the attributes must change — hence the companion `_lastKeyColorKey`.

Symbols render a step brighter than the codec text, at full `secondaryLabelColor`, matching the time labels — which is why both corner labels carry their dimming in the text color (`tertiaryLabelColor` in `cornerTextAttributes`) at full field alpha, not the old field-wide 0.5: a field alpha would dim the symbols too, and the codec/BPM lines are one visual pair. Template images, so the tint follows the label through appearance changes.

The line has two independent inputs — codec text and FX state — and `TrackDisplayController` composes it from the last of each, because FX are deck state that outlives any track: they persist across track changes and into the empty state. The refresh funnel that keeps it live is behavior; see `CLAUDE.md`.

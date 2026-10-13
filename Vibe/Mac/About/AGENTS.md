# About window (macOS)

This directory holds the About window (`AboutWindowController`). It also holds the two views drawn in it, `VectorBallsView` and `VibeLinkLabel`.

Vibe > About Vibe is a fixed 460×340 window with no nib, built in `init`. **`AppDelegate` is the only implementer of `showAboutWindow:`.** The app menu's item targets it directly. Settings > About's app-icon button is nil-targeted and reaches the same method up the responder chain. `AppDelegate` owns the single instance and keeps it alive across closes. `applyAuxiliaryWindowLevels` runs before each open, so a floating player cannot bury the window (`Mac/App/AGENTS.md`).

## VectorBallsView

"VIBE" as a dot matrix of shaded spheres spinning in 3D, on an `MTKView`. It sits above everything else in the window. Its clear color is transparent, so the record artwork and the text labels show through it. It takes no clicks, so the labels and the window's background drag still work.

**The view lives only while the window is open.** `windowWillClose:` drops the view and its per-view Metal resources. The device and compiled pipeline stay cached for later opens. Closing stops the render loop. `showWindow:` builds a fresh one (`rebuildBallsView`), which also replays the intro. `windowDidChangeOcclusionState:` pauses the 60 fps render loop whenever the window cannot be seen.

## VibeLinkLabel

An `NSTextField` with **one clickable range**, hit-tested against the link's own glyphs. A selectable `NSTextField` would give links for free, but these labels span the window's full width while their text is short and centered. Selectability would turn a full-width strip into an I-beam that also swallows the window's background drag. Hit-testing the glyphs means only those characters take the click, the pointing-hand cursor and the focus ring.

With no link set it is an ordinary label: not focusable, not an accessibility link, transparent to hits. `VibeLinkLabelTests` pins both halves. It is a link named by its visible line, focusable *only* while it carries one, and activated by Return and Space alone. The name's glyphs take the click, and the rest of the line does not.

**TRAP: this window is reused (`releasedWhenClosed = NO`), so first responder survives a close.** A focused link would come back with its ring drawn on a window the user just opened. `windowWillClose:` clears it with `makeFirstResponder:nil`, beside the Metal teardown.

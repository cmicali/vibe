# About window (macOS)

This directory holds the About window (`AboutWindowController`). It also holds `VectorBallsView`, which is drawn in it. The window's links are `VibeLinkLabel`s, from vibe-libs' `ui/Controls`.

Vibe > About Vibe is a fixed 460×340 window with no nib, built in `init`. **`AppDelegate` is the only implementer of `showAboutWindow:`.** The app menu's item targets it directly. Settings > About's app-icon button is nil-targeted and reaches the same method up the responder chain. `AppDelegate` owns the single instance and keeps it alive across closes. `applyAuxiliaryWindowLevels` runs before each open, so a floating player cannot bury the window (`Mac/App/AGENTS.md`).

## VectorBallsView

"VIBE" as a dot matrix of shaded spheres spinning in 3D, on an `MTKView`. It sits above everything else in the window. Its clear color is transparent, so the record artwork and the text labels show through it. It takes no clicks, so the labels and the window's background drag still work.

**The view lives only while the window is open.** `windowWillClose:` drops the view and its per-view Metal resources. The device and compiled pipeline stay cached for later opens. Closing stops the render loop. `showWindow:` builds a fresh one (`rebuildBallsView`), which also replays the intro. `windowDidChangeOcclusionState:` pauses the 60 fps render loop whenever the window cannot be seen.

## VibeLinkLabel

The window's link lines are `VibeLinkLabel`s. vibe-libs' `ui/Controls/AGENTS.md` describes the label, and its tests live there. These labels span the window's full width while their text is short and centered. So only the link's glyphs take the click, and the window's background drag still works around them.

**TRAP: this window is reused (`releasedWhenClosed = NO`), so first responder survives a close.** A focused link would come back with its ring drawn on a window the user just opened. `windowWillClose:` clears it with `makeFirstResponder:nil`, beside the Metal teardown.

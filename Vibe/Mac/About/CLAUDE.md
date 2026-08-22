# About window (macOS)

Vibe > About Vibe: a fixed 460×340 panel, no nib, built in `init`. **`AppDelegate` is the only implementer of `showAboutWindow:`**, which is why the app menu's item targets it directly while Settings > About's app-icon button is nil-targeted and reaches the same method up the responder chain — one opener, two doors. `AppDelegate` owns the single instance and keeps it alive across closes, and `applyAuxiliaryWindowLevels` runs before each open so the window rides at the player's level and a floating player cannot bury it (`Mac/Settings/CLAUDE.md`).

Three files, and only two of them have anything to know.

## VectorBallsView

Demoscene vectorballs: "VIBE" as a dot matrix of shaded spheres spinning in 3D, on an `MTKView`. It is the whole window's backdrop, and the content view's background matches the Metal clear color so the text strip below blends into it.

**The intro replays by rebuilding the whole view**, in `AboutWindowController.rebuildBallsView`. There is deliberately **no restart API**: mutating the instance buffer on a live view would race command buffers already in flight. So `showWindow:` builds a fresh view each open and `windowWillClose:` drops it with its Metal resources.

`windowDidChangeOcclusionState:` pauses the 60fps render loop whenever the window cannot be seen. A 3D animation nobody is looking at is exactly the kind of wakeup the rest of the app is careful about — see the root `CLAUDE.md`'s equalizer guarantee for the same rule stated where it is load-bearing.

## VibeLinkLabel

An `NSTextField` with **one clickable range**, hit-tested against the link's own glyphs.

A selectable `NSTextField` would give links for free and is the wrong shape here: these labels span the window's full width while their text is centered and short, so selectability turns a full-width strip into an I-beam that also swallows the window's background drag. Hit-testing the glyphs means only those characters take the click, the pointing-hand cursor and the focus ring, and the rest of the label stays transparent.

With no link set it is an ordinary label — not focusable, not an accessibility link, hit-test transparent everywhere. It is the one class here with unit tests (`VibeLinkLabelTests`), which pin both halves: the accessibility contract — it is a link named by its visible line, focusable *only* while it carries one, activated by Return and Space and nothing else — and the hit-testing, that the name's glyphs take the click and the rest of the line does not.

**TRAP: this window is reused (`releasedWhenClosed = NO`), so first responder survives a close.** A link left focused comes back with its ring already drawn on a window the user just opened fresh — `windowWillClose:` clears it with `makeFirstResponder:nil`, beside the Metal teardown.

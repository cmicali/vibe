# Themes

A theme restyles the whole player: the window background and tint, the corner
radius, every font and text color, the waveform's style and colors, the
playlist's look, and the artwork placeholder shown when a track has none.

Vibe ships with a few built-in themes, and you can build and share your own.

## Switching themes

Open **Settings > Appearance** (`⌘,`). Clicking a theme in the list applies it
immediately — there is no separate Apply step. The **View > Theme** menu
switches themes too, without opening Settings.

The **Appearance** dropdown above the list (Auto / Light / Dark) is separate
from the theme: it picks the window's light or dark look, and a theme that has
both palettes follows it.

The **Waveform** dropdown beneath it changes the waveform's drawing style
without opening the theme editor. It is part of the theme — switching themes
switches it too — but your pick here overrides the theme's own: over a
built-in theme the override sticks, across relaunches, until you re-apply a
theme; editing your own theme this way simply changes the theme.

## Creating your own

In **Settings > Appearance**:

1. Click **Add > New Theme** to start from the player's current look — or
   select the built-in theme closest to what you want and choose
   **Add > Duplicate**. Built-in themes are read-only; your copy is yours to
   edit.
2. Click **Edit…** (or double-click the theme) to open the editor. Changes
   apply live, so keep a track playing and watch the player as you go.
3. Name it at the top of the editor page.

The editor is organized the way the player is: **Window** (background, tint,
corner radius), **Player** (default artwork, title and artist fonts and
colors), **Info** (the file-info line, times, BPM and key), **Waveform**
(style, colors, gradient), and **Playlist** (background, fonts, columns, row
highlights).

Two things worth knowing:

- **Light & Dark Modes vs. Single Mode** — the editor's Appearance dropdown
  decides whether your theme keeps a separate color set for light and dark
  (and follows the window's appearance), or one set of colors used
  everywhere. In Single Mode each color row shows one swatch instead of a
  Dark/Light pair. While editing a dual-mode theme, the sun/moon toggle in
  the window's toolbar previews either side.
- **Every color swatch includes opacity.** A tint's strength, a solid
  background's coverage, and each waveform side's intensity are all set with
  the color panel's opacity slider.

## Custom artwork

The **Default artwork** row in the Player section sets the placeholder drawn
when a track has no cover art — one image for dark, one for light (or a
single image in Single Mode). Click a preview to choose your own image: a
square JPEG or PNG, between 64 and 4096 pixels, up to 8 MB. Hover over a
preview and click the **✕** to go back to the factory artwork.

## Sharing a theme

Select your theme and click **Export…**. A theme with no custom artwork saves
as a small, readable `.json` file; one with custom artwork saves as a `.zip`
carrying the theme and its images together. Either file is the whole theme —
send it however you like.

To install a theme someone sent you, drag the file onto the theme list in
**Settings > Appearance**, or choose **Add > Import…** — both `.json` and
`.zip` work. Importing never replaces anything: if the name is already taken,
Vibe suffixes the new one (“My Theme 2”), and imported artwork is re-validated
on the way in.

The exported JSON is meant to be readable: it stores only what your theme
changes from the factory look, grouped by editor section. Hand-editing is
safe to try — a value Vibe doesn't understand is ignored on import rather
than breaking the theme.

If you assemble a `.zip` by hand, reference the artwork by filename:
`"defaultArtworkDark": "cover_dark.png"` names a `cover_dark.png` packed in
the same archive (a `custom:` prefix on the name also works). Vibe's own
exports name images by a content hash, and it renames yours the same way on
import.

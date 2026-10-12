# Themes

A theme restyles the whole Mac player: the window background and tint, the corner radius, every font and text color, the waveform's style and colors, the playback buttons, the volume slider, the playlist's look, and the artwork placeholder shown when a track has none.

Vibe ships with a few built-in themes, and you can build and share your own.

## Switching themes

Open **Settings > Themes** (`⌘,`). Click a theme in the list to apply it at once. The **View > Theme** menu switches themes too, without opening Settings.

The **Window appearance** dropdown in **Settings > Appearance** (Follow System, Light or Dark) picks the light or dark look of a theme that has both. A Single Mode theme keeps the window dark and disables that dropdown.

The **Waveform style** dropdown above the theme list changes the waveform's drawing style without opening the editor. The style is part of the theme, so switching themes switches it too. Over a built-in theme, your pick stays across relaunches until you apply a theme again. The **Revert** button beside the theme's name puts the theme's own look back. Over your own theme, the pick simply changes the theme.

## Creating your own

In **Settings > Themes**:

1. Click **Add > New Theme** to start from the player's current look. Or select the built-in theme closest to what you want and choose **Add > Duplicate**. Built-in themes are read-only, and your copy is yours to edit.
2. Click **Edit Theme…**, or double-click the theme, to open the editor. Changes apply live, so keep a track playing and watch the player as you go.
3. Name it at the top of the editor page.

You can also select a built-in theme and click **Customize…**. The editor opens with its current look, and your first edit saves an editable copy.

The editor follows the player's layout: **App icon**, **Window** (color modes, background, tint, corner radius), **Player display** (default artwork, the waveform, title and artist fonts and colors), **Playback buttons**, **Track information** (the readouts' font and colors), **Volume slider**, and **Playlist**.

What the player shows is not part of a theme. The readouts, the playlist's columns and the Dock icon are under **Settings > Appearance**, and they stay put when you switch themes.

Two things worth knowing:

- **Light & Dark Modes or Single Mode.** The editor's **Theme color modes** dropdown decides whether your theme keeps separate colors for light and dark, or one set used everywhere. A Light & Dark theme follows the window's appearance. In Single Mode each color row shows one swatch instead of a Dark and Light pair. While you edit a Light & Dark theme, the sun and moon toggle in the Settings toolbar previews either side.
- **Every color swatch includes opacity.** Use the color panel's opacity slider to set a tint's strength, a solid background's coverage, or each waveform side's intensity. The 3-Band style's Low, Mid and High colors are the exception. Its bands stack, so they always draw opaque.

## Custom artwork

The **Default artwork** row in Player display sets the placeholder drawn when a track has no cover art. It takes one image for dark and one for light, or a single image in Single Mode. Click a preview to choose your own image: a square JPEG or PNG, from 64 to 4096 pixels, up to 8 MB. Hover over a preview and click the **✕** to go back to the factory artwork.

## Sharing a theme

Select your theme and click **Export…**. A theme with no custom artwork saves as a small, readable `.json` file. A theme with custom artwork saves as a `.zip` that holds the theme and its images. Either file is the whole theme, so send it however you like.

To install a theme someone sent you, drag the file onto the theme list in **Settings > Themes**, or choose **Add > Import…**. Both `.json` and `.zip` work. Importing never replaces anything. If the name is already taken, Vibe adds a number to the new one ("My Theme 2"). Imported artwork is checked again on the way in.

The exported JSON stores only what your theme changes from the factory look, grouped into sections. You can edit it by hand. Vibe ignores a value it doesn't understand rather than breaking the theme.

If you build a `.zip` by hand, name the artwork by its filename. `"defaultArtworkDark": "cover_dark.png"` names a `cover_dark.png` in the same archive. Vibe renames each image by a hash of its content when it imports it.

Built-in themes are made the same way. `Resources/Themes-README.md` explains how to add one to the app.

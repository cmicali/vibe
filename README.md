# Vibe

A fast and minimal winamp-inspired native music player for macOS. Built with DJs in mind with large local libraries, lossless files, and the need to quickly sort and scrub through tracks.

![Vibe screenshot](Assets/screenshot-basic.png)

## Features

- **Format support** — MP3, MP2, AAC, FLAC, MP4/M4A, AIFF, and WAV, all decoded natively by CoreAudio
- **Waveform seek bar** — SoundCloud style waveform with click-to-seek.
- **Drag & drop playlists** — drop files or folders onto the window or dock icon to play
- **Metadata & artwork** — Metadata and artwork pulled via TagLib
- **Performance** — Optimized code and caching keep things quick
- **Keyboard transport** — `Space` play/pause, `B` previous track, `N` next track
- **Pitch Adjust** — SL-1200 style optional pitch adjustment

## Requirements

- macOS 26 or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — the Xcode project is generated from `project.yml`

## Setup

1. Install XcodeGen

   ```
   brew install xcodegen
   ```

## Building

1. Generate the project file

   ```
   xcodegen generate
   ```

2. Open the project in Xcode:

   ```
   open Vibe.xcodeproj
   ```

3. Build and run the `Vibe` scheme (⌘R).

Alternatively, run `scripts/build.sh` to build `build/DerivedData/Build/Products/Release/Vibe.app`

## Localization

English is the source language. All user-facing strings live in `Vibe/Common/Strings.h`; translations live in `Resources/Localizable.xcstrings` (plus `Resources/InfoPlist.xcstrings` for the bundle name, copyright, and document-type names). The app ships every language present in those catalogs — to see the current set, run `jq -r '[.strings[].localizations | keys] | flatten | unique' Resources/Localizable.xcstrings`.

### Adding or changing a string

1. Add (or edit) a one-line `NSLS(key, value, comment)` entry in `Vibe/Common/Strings.h` — symbolic key (`menu.file`), English text, translator comment. Use the `STR_*` macro at the call site; never an inline `NSLocalizedString` or bare literal (mark deliberately-English strings `VibeNotLocalized(...)`).
2. Run `make strings` to sync the catalog (needs `jq` — `make setup`). This is a manual step; the build does not extract strings.
3. Translate the new key into every shipping language in `Resources/Localizable.xcstrings` (Xcode's catalog editor, or edit the JSON). Extraction never touches non-English translations, so existing ones are safe.

`make check-strings` fails if the catalog is out of sync (including keys whose last call site was removed — delete their `Strings.h` entries).

### Adding a language

1. Open `Resources/Localizable.xcstrings` in Xcode and add the language (or add the language's `stringUnit` per key in the JSON, `state: "translated"`). Do the same for `Resources/InfoPlist.xcstrings`. Follow Apple's own macOS terminology for the standard menu items rather than translating literally — the menus should read like the rest of the system.
2. Rebuild. Nothing else changes — no `project.yml` or `knownRegions` edits; the build ships every language present in the catalogs.
3. Test it by launching with that language code (see below) and check the tight spots: the menu bar, the 96pt pitch-panel title, the drop hint, and the inline error text.

### Running in a specific language

Pass the language as a launch argument — it overrides the app for that run only, changing nothing system-wide:

```bash
open build/DerivedData/Build/Products/Debug/Vibe.app --args -AppleLanguages '(fr)'
```

Quit any running instance first, or `open` will just front the existing one. To open a file too, put it before `--args`.

## Usage

Drop audio files or a music folder onto the window to play. Click the waveform to seek/skip in the track.

Drag and drop the artwork to copy the currently playing file to another folder.

### Key commands

| Key | Action |
| --- | --- |
| `Space` | Play / pause |
| `B` | Previous track |
| `N` | Next track |
| `A` / `S` / `D` | Skip forward (8 / 16 / 32 bars when the tempo is known) |
| `Z` / `X` / `C` | Skip back (8 / 16 / 32 bars when the tempo is known) |
| `Q` | Toggle low-kill filter |
| `W` `E` `R` `T` (hold) | Momentary FX: low-kill boost, reverb wash, 1/8- and 1/16-note delay |
| `Tab` | Show / hide playlist |
| `P` | Show / hide pitch control |
| `⌘O` | Open file or folder |

## Screenshots

#### Pitch control

![Vibe screenshot](Assets/screenshot-pitch.png)

#### Playlist

![Vibe screenshot](Assets/screenshot-playlist.png)

#### Playlist + Pitch

![Vibe screenshot](Assets/screenshot-playlist-pitch.png)

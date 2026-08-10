# Vibe

A fast, minimal music player for the Mac. No third-party engine, no account, no subscription. Just a simple, fast player for your files. 

![Vibe screenshot](Assets/screenshot-basic.png)

[![Download on the App Store](https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-app-store/black/en-us?releaseDate=1374883200)](https://apps.apple.com/us/app/vibe-music-player/id1582482361?mt=12)

## Features

- **Formats** — MP3, MP2, AAC, FLAC, MP4/M4A, AIFF and WAV, all decoded natively by CoreAudio
- **Waveform seek bar** — a SoundCloud-style waveform; click it to seek
- **Drag and drop** — drop files or folders on the window or the dock icon to play them
- **Metadata and artwork** — read with TagLib, then cached to disk
- **Keyboard transport** — `Space` plays and pauses, `B` and `N` change track, `A`–`D` and `Z`–`C` skip by bars
- **Performance FX** — a low-kill filter, a reverb wash and BPM-synced delays on `Q`–`T`; tap to latch, hold for momentary
- **Pitch adjust** — an optional SL-1200-style pitch fader

![Vibe screenshot](Assets/screenshot-playlist.png)

## Localization

English is the source language. All user-facing strings live in `Vibe/Common/Strings.h`; translations live in `Resources/Localizable.xcstrings` (plus `Resources/InfoPlist.xcstrings` for the bundle name, copyright, and document-type names). The app ships every language present in those catalogs — to see the current set, run `jq -r '[.strings[].localizations | keys] | flatten | unique' Resources/Localizable.xcstrings`.

### Adding or changing a string

1. Add (or edit) a one-line `NSLS(key, value, comment)` entry in `Vibe/Common/Strings.h` — symbolic key (`menu.file`), English text, translator comment. Use the `STR_*` macro at the call site; never an inline `NSLocalizedString` or bare literal (mark deliberately-English strings `VibeNotLocalized(...)`).
2. Run `make strings` to sync the catalog (needs `jq` — `make setup`). This is a manual step; the build does not extract strings.
3. Translate the new key into every shipping language in `Resources/Localizable.xcstrings` (Xcode's catalog editor, or edit the JSON). Extraction never touches the *text* of non-English translations; rewording a string's English flips them to `needs_review` (they keep shipping until re-reviewed).

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

Drop audio files or a folder on the window to play them. Click the waveform to seek.

Drag the artwork out to copy the playing file somewhere else.

### Key commands

| Key | Action |
| --- | --- |
| `Space` | Play / pause |
| `B` | Previous track |
| `N` | Next track |
| `A` / `S` / `D` | Skip forward 8 / 16 / 32 bars when the tempo is known, else 10 / 30 / 60 seconds |
| `Z` / `X` / `C` | Skip back 8 / 16 / 32 bars when the tempo is known, else 10 / 30 / 60 seconds |
| `Tab` | Show / hide playlist |
| `P` | Show / hide pitch control |
| `⌘O` | Open file or folder |

#### FX

| Key | Action |
| --- | --- |
| `Q` | Low-kill filter |
| `W` | Low-kill boost, which pushes the `Q` cutoff higher |
| `E` | Reverb wash |
| `R` | Delay, 1/8-note taps |
| `T` | Delay, 1/16-note taps |

Tap an FX key to latch the effect; hold it for momentary.

![Vibe screenshot](Assets/screenshot-pitch.png)

![Vibe screenshot](Assets/screenshot-playlist-pitch.png)

# Development

Vibe is written in Objective-C/C++ and is focused on performance and speed. It uses CoreAudio directly
and avoids 3rd-party libraries where possible. TagLib 1.3 is included in-tree and used for reading 
metadata and artwork.

## Requirements

- macOS 26 or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `Vibe.xcodeproj` is generated from `project.yml` and is not checked in

## Setup

Install the dev tools listed in the `Brewfile`:

```bash
make setup
```

## Building

Generate the project file, then open it:

```bash
xcodegen generate && open Vibe.xcodeproj
```

Build and run the `Vibe` scheme with ⌘R. Re-run `xcodegen generate` after every pull or edit to `project.yml`.

To build from the command line instead, run `scripts/build.sh`. It writes `build/DerivedData/Build/Products/Release/Vibe.app`.

## Releasing

The full Mac App Store release process — credentials, localized product-page assets, metadata upload, and shipping a build — is documented in [RELEASING.md](RELEASING.md).

# License

Vibe is licensed under the [Apache License 2.0](LICENSE).

There is no package manager: all third-party code is vendored under `Vibe/ThirdParty/` and compiled into the app target. [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists every component and the license it is used under — most notably TagLib, which is dual-licensed and which Vibe uses under the Mozilla Public License 1.1 rather than the LGPL, because it is statically linked.

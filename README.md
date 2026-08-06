# Vibe

A fast, minimal, Winamp-inspired music player for macOS. It is built for DJs: big local libraries, lossless files, and the need to sort and scrub through tracks in a hurry.

![Vibe screenshot](Assets/screenshot-basic.png)

## Features

[![Download on the App Store](https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-app-store/black/en-us?releaseDate=1374883200)](https://apps.apple.com/us/app/vibe-music-player/id1582482361?mt=12)

- **Formats** — MP3, MP2, AAC, FLAC, MP4/M4A, AIFF and WAV, all decoded natively by CoreAudio
- **Waveform seek bar** — a SoundCloud-style waveform; click it to seek
- **Drag and drop** — drop files or folders on the window or the dock icon to play them
- **Metadata and artwork** — read with TagLib, then cached to disk
- **Keyboard transport** — `Space` plays and pauses, `B` and `N` change track, `A`–`D` and `Z`–`C` skip by bars
- **Performance FX** — a low-kill filter, a reverb wash and BPM-synced delays on `Q`–`T`; tap to latch, hold for momentary
- **Pitch adjust** — an optional SL-1200-style pitch fader

## Usage

Drop audio files or a folder on the window to play them.

Click the waveform to seek.

![Vibe screenshot](Assets/screenshot-playlist.png)

Drag the artwork out to copy the playing file somewhere else.

![Vibe screenshot](Assets/screenshot-pitch.png)

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

![Vibe screenshot](Assets/screenshot-playlist-pitch.png)

# Development

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

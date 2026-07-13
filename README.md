# Vibe

A fast and minimal winamp-inspired native music player for macOS. Built for large local libraries and lossless files. 

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

- macOS 10.15 or later
- Xcode
- [CocoaPods](https://cocoapods.org)

## Building

1. Install dependencies:

   ```
   pod install
   ```

2. Open the workspace (not the project — CocoaPods manages dependencies through the workspace):

   ```
   open Vibe.xcworkspace
   ```

3. Build and run the `Vibe` scheme (⌘R).

## Running

Launch the app, then drop audio files or a music folder onto the window (or the dock icon).

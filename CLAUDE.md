# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Install dependencies (CocoaPods)
pod install

# Build via Xcode (use .xcworkspace, not .xcodeproj)
open Vibe.xcworkspace
```

Build and run through Xcode using the `Vibe` scheme. Always open `Vibe.xcworkspace` (not `.xcodeproj`) because CocoaPods manages dependencies through the workspace.

There are no unit tests in this project.

## Architecture

Vibe is a native macOS music player written in Objective-C/Objective-C++. It uses the [BASS audio library](http://www.un4seen.com) for playback, with dylibs (`libbass.dylib`, `libbassflac.dylib`) embedded from `Libraries/bass/`.

### Core Components

**Audio Playback Pipeline:**
- `AudioPlayer` wraps the BASS library and manages HSTREAM channels. All BASS calls are dispatched to a dedicated `WorkQueueThread` (custom NSThread subclass) for thread safety. UI updates are dispatched back to main thread via `run_on_main_thread()` macro.
- `AudioTrack` is the data model for a track (URL, lazy-loaded duration, file hash for cache keys).
- `AudioTrackMetadata` extracts metadata (title, artist, album art, codec info) using TagLib. Results are persisted via `AudioTrackMetadataCache` (PINCache-backed).
- `CoreAudioUtil` handles system audio device change listeners and sample rate management.
- `BassUtil` provides BASS API helpers: volume ramping with `BASS_ChannelSlideAttribute`, position conversion (bytes ↔ seconds), and C callback registration.

**Waveform System (two-layer architecture):**
- *Data layer* (`Audio/Waveform/`): `AudioWaveform` is a C++ data structure storing min/max float pairs per chunk. `BASSAudioWaveformLoader` generates waveform data from audio files asynchronously. `AudioWaveformCache` persists waveform data via PINCache.
- *Rendering layer* (`Waveform/`): `AudioWaveformView` is a CALayer-based NSView that delegates rendering to strategy objects. Renderer hierarchy: `AudioWaveformRenderer` (base) → `BasicAudioWaveformRenderer`, `DetailedAudioWaveformRenderer`, `OversamplingDetailedAudioWaveformRenderer` (x2/x4/x8 variants). The default style is "Oversampling Detailed x4" (configurable in `AppSettings`).

**UI Architecture (AppKit/MVC):**
- `MainPlayerController` (NSWindowController) is the central coordinator. It implements `AudioPlayerDelegate`, `AudioWaveformViewDelegate`, `AudioTrackMetadataManagerDelegate`, and `FileDropDelegate`. A 3 Hz dispatch timer drives UI updates.
- `MainWindow` is a custom NSWindow that accepts file drag-and-drop (NSDraggingDestination) and supports small/large layout toggle.
- `PlaylistManager` manages the track list as NSTableViewDataSource/Delegate with custom cells for track number, artwork thumbnail, title/artist, and duration.
- `OutputDevicesMenuController` populates the audio device selection menu from `AudioDeviceManager` (singleton).
- XIB-based layout: `MainPlayerWindow.xib` for the main UI, `MainMenu.xib` for the app menu.

### Dependencies (CocoaPods)

- **CocoaLumberjack**: Logging (`LogDebug`, `LogInfo`, etc. macros via `DDLogLevel`)
- **taglib-pod**: Audio metadata extraction (custom pod from `github.com/cmicali/taglib-pod`)
- **PINCache**: Disk/memory caching for metadata and waveform data

### Key Patterns

- **Delegation** is used throughout: AudioPlayer → MainPlayerController, waveform views → controller, metadata cache → controller.
- **Singletons**: `AppSettings`, `AudioDeviceManager`.
- **File hashing**: `NSURL+Hash` provides SHA1 hashing used as cache keys for metadata and waveform data.
- **ObjC++ (.mm files)**: Used wherever C++ is needed — BASS API calls, TagLib integration, waveform data structures, and CoreAudio utilities.

### Supported Audio Formats

MP3, FLAC (via libbassflac), MP4/M4A, AIFF, WAV, OGG.

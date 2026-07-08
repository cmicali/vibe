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

Vibe is a native macOS music player written in Objective-C/Objective-C++. Playback is built entirely on Apple frameworks (AVFAudio/AVAudioEngine + CoreAudio) with no third-party audio library — CoreAudio decodes MP3 and FLAC natively. The only external dependencies are the CocoaPods below.

### Core Components

**Audio Playback Pipeline:**
- `AudioPlayer` drives an `AVAudioEngine` with a fresh `AVAudioPlayerNode` per track. State machine: `{Stopped, Playing, Paused, Loading}` — `Loading` covers the in-flight file open (reports `isPlaying`, zero position/duration). All engine mutation runs on a serial `dispatch_queue` (`com.vibe.audioplayer`, user-initiated QoS); UI-facing getters (`position`/`duration`/`isPlaying`) read state under an `os_unfair_lock` and never block. Two generation counters disambiguate async work: `_generation` for stale `scheduleSegment` completions, `_rampGeneration` for cancelling in-flight volume fades (stop/seek/skip/device-switch bump them first). A last-valid-position cache preserves the playhead when the engine stops itself (device unplug/format change) before recovery can read it. Files are opened off-queue with a timeout so an undownloaded iCloud/Dropbox placeholder can't wedge playback; a slow open surfaces a loading state. The engine is stopped when playback goes idle (releases the output device) and restarts lazily on the next play. UI updates are dispatched back to the main thread via the `run_on_main_thread()` macro.
- `AudioTrack` is the data model for a track (URL, lazy-loaded duration, file hash for cache keys).
- `AudioTrackMetadata` extracts metadata (title, artist, album art, codec info) using TagLib. Results are persisted via `AudioTrackMetadataCache` (PINCache-backed, `NSSecureCoding`; failed parses are shown but never cached, via `parsedOK`). Art memory lifecycle: the disk cache stores only a 128px thumbnail JPEG; full-res art is decoded on demand (capped at 1024px via ImageIO) for the current track only and demoted (`discardDecodedAlbumArt`) when the track changes. Locks are never held across file I/O or image decode — cloud files can block reads indefinitely.
- `CoreAudioUtil` handles system audio device change listeners and sample-rate management (nominal-rate selection over the device's supported ranges).

**Waveform System (two-layer architecture):**
- *Data layer* (`Audio/Waveform/`): `AudioWaveform` is a C++ data structure storing min/max float pairs per chunk. `AVFAudioWaveformLoader` (backed by `AVAudioFile`) generates waveform data asynchronously on the cache's serial loader queue, handing immutable snapshots to the main thread for progressive rendering. `AudioWaveformCache` persists waveform data via PINCache.
- *Rendering layer* (`Waveform/`): `AudioWaveformView` is a CALayer-based NSView that delegates rendering to strategy objects. Renderer hierarchy: `AudioWaveformRenderer` (base) → `BasicAudioWaveformRenderer`, `DetailedAudioWaveformRenderer`, `OversamplingDetailedAudioWaveformRenderer` (x2/x4/x8 variants). The default style is "Oversampling Detailed x4" (configurable in `AppSettings`).

**UI Architecture (AppKit/MVC):**
- `MainPlayerController` (NSWindowController) is the central coordinator. It implements `AudioPlayerDelegate`, `AudioWaveformViewDelegate`, `AudioTrackMetadataManagerDelegate`, and `FileDropDelegate`. A 3 Hz dispatch timer drives UI updates. Metadata loading for a dropped playlist is deferred until playback starts (2 s fallback) so the first track plays immediately on large folder drops.
- `MainWindow` is a custom NSWindow that accepts file drag-and-drop (NSDraggingDestination) and supports small/large layout toggle. Dropped folders expand on a serial queue (`NSURLUtil`) so overlapping drops complete in submission order; files keep filesystem order (no sorting).
- `PlaylistManager` manages the track list as NSTableViewDataSource/Delegate with custom cells for track number, artwork thumbnail, title/artist, and duration.
- `OutputDevicesMenuController` populates the audio device selection menu from `AudioDeviceManager` (singleton). The menu's device-marker icons are template images (tinted automatically for light/dark menus).
- `About/` contains the About window: `AboutWindowController` plus `VectorBallsView`, an MTKView Metal animation (paused while the window is occluded).
- XIB-based layout: `MainPlayerWindow.xib` for the main UI, `MainMenu.xib` for the app menu.

### Dependencies (CocoaPods)

- **CocoaLumberjack**: Logging (`LogDebug`, `LogInfo`, etc. macros via `DDLogLevel`)
- **taglib-pod**: Audio metadata extraction (custom pod from `github.com/cmicali/taglib-pod`)
- **PINCache**: Disk/memory caching for metadata and waveform data

### Key Patterns

- **Delegation** is used throughout: AudioPlayer → MainPlayerController, waveform views → controller, metadata cache → controller.
- **Singletons**: `AppSettings`, `AudioDeviceManager`.
- **File hashing**: `NSURL+Hash` provides SHA1 hashing used as cache keys for metadata and waveform data.
- **ObjC++ (.mm files)**: Used wherever C++ is needed — TagLib integration, waveform data structures, and CoreAudio utilities.

### Supported Audio Formats

MP3, MP2, FLAC, MP4/M4A, AAC, AIFF, WAV (all decoded natively by CoreAudio). OGG is not supported.

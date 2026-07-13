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

## Debugging / Verification

To launch, drive, inspect, or screenshot the app — anything involving verifying a change against the running app — use the **`vibe-debug` skill** (`.claude/skills/vibe-debug/`). It documents the debug command channel (`Vibe --debug-cmd state|viewtree|screenshot|playPause|…`, debug builds only, defined in `Debug/DebugUtil.m`), both screenshot paths (the in-process snapshot helper cannot render `NSVisualEffectView` materials or Metal content — real `screencapture` is required for background/appearance checks), sandbox launch pitfalls (`open -a` vs raw argv, Xcode-run instances shadowing your build), and bundles scripts for window capture and pixel probing.

## Architecture

Vibe is a native macOS music player written in Objective-C/Objective-C++. Playback is built entirely on Apple frameworks (AVFAudio/AVAudioEngine + CoreAudio) with no third-party audio library — CoreAudio decodes MP3 and FLAC natively. The only external dependencies are the CocoaPods below.

### Core Components

**Audio Playback Pipeline:**
- `AudioPlayer` drives an `AVAudioEngine` with a fresh `AVAudioPlayerNode` per track. State machine: `{Stopped, Playing, Paused, Loading}` — `Loading` covers the in-flight file open (reports `isPlaying`, zero position/duration). All engine mutation runs on a serial `dispatch_queue` (`com.vibe.audioplayer`, default QoS); UI-facing getters (`position`/`duration`/`isPlaying`) read state under an `os_unfair_lock` and never block. Two generation counters disambiguate async work: `_generation` for stale `scheduleSegment` completions, `_rampGeneration` for cancelling in-flight volume fades (stop/seek/skip/device-switch bump them first). All fades (~50ms pause/resume/skip ramps) are asynchronous — the queue never sleeps. On skip, the outgoing node is rerouted onto its own mixer input before its fade-out, because the incoming track's connect replaces the shared varispeed input and would otherwise hard-cut it. A last-valid-position cache preserves the playhead when the engine stops itself (device unplug/format change) before recovery can read it. Files are opened off-queue with a timeout so an undownloaded iCloud/Dropbox placeholder can't wedge playback; a slow open surfaces a loading state. The engine is stopped when playback goes idle (releases the output device) and restarts lazily on the next play. UI updates are dispatched back to the main thread via the `run_on_main_thread()` macro.
- `AudioTrack` is the data model for a track (URL, lazy-loaded duration, file hash for cache keys).
- `AudioTrackMetadata` extracts metadata (title, artist, album art, codec info) using TagLib. Results are persisted via `AudioTrackMetadataCache` (PINCache-backed, `NSSecureCoding`; failed parses are shown but never cached, via `parsedOK`). Art memory lifecycle: the disk cache stores only a 128px thumbnail JPEG; full-res art is decoded on demand (capped at 1024px via ImageIO) for the current track only and demoted (`discardDecodedAlbumArt`) when the track changes. Locks are never held across file I/O or image decode — cloud files can block reads indefinitely.
- `CoreAudioUtil` is a stateless set of raw HAL property accessors (device IDs, UIDs, names, output-channel checks). `AudioDeviceManager` (singleton) owns device-change listening: it registers CoreAudio listeners for the default output device and the device list at init (process lifetime, never removed) and fans out to weakly-held observers (`AudioDeviceManagerObserver`: `AudioPlayer`, `OutputDevicesMenuController`) on the main thread in the common run-loop modes — GCD main-queue blocks don't run during menu tracking, and the devices menu refreshes while open.

**Waveform System (two-layer architecture):**
- *Data layer* (`Audio/Waveform/`): `AudioWaveform` is a C++ data structure storing min/max float pairs per chunk. `AVFAudioWaveformLoader` (backed by `AVAudioFile`) generates waveform data asynchronously on the cache's serial loader queue, handing immutable snapshots to the main thread for progressive rendering. `AudioWaveformCache` persists waveform data via PINCache.
- *Rendering layer* (`Waveform/`): `AudioWaveformView` is a CALayer-based NSView that delegates rendering to strategy objects. Renderer hierarchy: `AudioWaveformRenderer` (base) → `VibeDefaultWaveformRenderer` and `DetailedAudioWaveformRenderer`; `BasicAudioWaveformRenderer` and `OversamplingDetailedAudioWaveformRenderer` (x2/x4/x8 variants) subclass `DetailedAudioWaveformRenderer`. The default style is "Oversampling Detailed x4" (configurable in `AppSettings`).
- The C++ waveform types stay out of ObjC headers: `AudioWaveformCache.h` forward-declares `CodableAudioWaveform` instead of importing `AudioWaveform.h`, so the UI layer compiles as plain ObjC (.m).

**UI Architecture (AppKit/MVC):**
- `MainPlayerController` (NSWindowController) is the central coordinator. It implements `AudioPlayerDelegate`, `AudioWaveformViewDelegate`, `AudioTrackMetadataCacheDelegate`, and `FileDropDelegate` — all in the class extension; the public header exposes only collaborators and actions, and the debug command channel's extra surface lives in `MainPlayerController+Debug.h`. A 3 Hz dispatch timer drives UI updates. Metadata loading for a dropped playlist is deferred until playback starts (2 s fallback) so the first track plays immediately on large folder drops.
- `MainWindow` is a custom NSWindow that accepts file drag-and-drop (NSDraggingDestination) and supports small/large layout toggle. Dropped folders expand on a serial queue (`NSURLUtil`) so overlapping drops complete in submission order; files keep filesystem order (no sorting).
- `PlaylistManager` manages the track list as NSTableViewDataSource/Delegate with custom cells for track number, artwork thumbnail, title/artist, and duration.
- `OutputDevicesMenuController` populates the audio device selection menu from `AudioDeviceManager` (singleton) and, as an `AudioDeviceManagerObserver`, rebuilds the menu in place if devices change while it is open. The menu's device-marker icons are template images (tinted automatically for light/dark menus).
- `About/` contains the About window: `AboutWindowController` plus `VectorBallsView`, an MTKView Metal animation (paused while the window is occluded).
- Programmatic layout, no nibs: `MainWindow` configures itself in `init` (borderless, frame autosave, drag-and-drop registration); the whole main-window view hierarchy lives in `MainPlayerContentView` (an `NSVisualEffectView` subclass exposing the subviews as readonly properties), which `MainPlayerController` adopts as its outlets in `buildContentInWindow:` (called from `init`; `windowDidLoad` is invoked manually since AppKit only fires it on the nib path). Playlist cell views are built in `PlaylistManager` (`makeCellViewWithIdentifier:`) and recycled through the table's normal reuse queue.
- App bootstrap (no main nib): `main.m` creates the `AppDelegate` (kept alive by a global — `NSApplication.delegate` is weak); `applicationWillFinishLaunching:` creates `MainPlayerController` (which owns its `OutputDevicesMenuController`) and installs the menu bar via `MainMenuBuilder`, which also backs the Open Recent submenu from `NSDocumentController.recentDocumentURLs`. Bare key equivalents must set `keyEquivalentModifierMask = 0` explicitly (`NSMenuItem` defaults to Command).

### Dependencies (CocoaPods)

- **taglib-pod**: Audio metadata extraction (custom pod from `github.com/cmicali/taglib-pod`)
- **PINCache**: Disk/memory caching for metadata and waveform data

### Logging

`LogError`/`LogWarn`/`LogInfo`/`LogDebug`/`LogTrace` macros (defined in `Vibe-Prefix.pch`) wrap Apple's unified logging (`os_log`) under subsystem `com.commonwealthrecordings.Vibe`. Info/debug messages are not persisted to the log store — stream them live with `/usr/bin/log stream --level debug --predicate 'subsystem == "com.commonwealthrecordings.Vibe"'` (use the full path; zsh has a `log` builtin).

### Key Patterns

- **Delegation** is used throughout: AudioPlayer → MainPlayerController, waveform views → controller, metadata cache → controller.
- **Singletons**: `AppSettings`, `AudioDeviceManager`.
- **File hashing**: `NSURL+Hash` provides the cache key for metadata and waveform data: `<size>-<mtime_us>-<sha1(path)>` from file attributes only (no content hash — cheap, but misses on rewrite or move).
- **ObjC++ (.mm files)**: Used only where C++ is actually needed — TagLib integration and the waveform data structures. Everything else (including the whole UI layer) is plain ObjC (.m); don't add C++ types to headers that ObjC files import.
- **Third-party sources** (`ThirdParty/`): `SYFlatButton`, `RSVerticallyCenteredTextFieldCell` — vendored code by other authors; don't restyle it.

### Supported Audio Formats

MP3, MP2, FLAC, MP4/M4A, AAC, AIFF, WAV (all decoded natively by CoreAudio). OGG is not supported.

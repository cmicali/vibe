# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

`Vibe.xcodeproj` is generated from `project.yml` by XcodeGen (`brew install xcodegen`) and is **not** checked in — regenerate it after cloning, pulling, or editing `project.yml`:

```bash
xcodegen generate          # or: make project
```

Then build in Xcode (open `Vibe.xcodeproj`, `Vibe` scheme, ⌘R) or from the command line:

```bash
# Release (app at build/DerivedData/Build/Products/Release/Vibe.app)
xcodebuild -project Vibe.xcodeproj -scheme Vibe -configuration Release \
    -derivedDataPath build/DerivedData build

# Debug — needed for the debug command channel; see Debugging / Verification
xcodebuild -project Vibe.xcodeproj -scheme Vibe -configuration Debug \
    -derivedDataPath build/DerivedData build
```

Convenience wrappers (each runs `xcodegen generate` first and writes to `build/DerivedData`): `make build` (Release; `make build CONFIG=Debug` for debug) or `scripts/build.sh [Debug|Release]`; `make release` (or `scripts/release.sh`) builds Release then signs with Developer ID, notarizes, and staples a distributable app.

There is no package manager — all third-party code is vendored under `Vibe/ThirdParty/` and compiles as part of the app target (CocoaPods was removed; TagLib and PINCache are now in-tree). Editing `project.yml` (adding files, changing build settings) means running `xcodegen generate` again.

There are no unit tests in this project.

## Debugging / Verification

To launch, drive, inspect, or screenshot the app — anything involving verifying a change against the running app — use the **`vibe-debug` skill** (`.claude/skills/vibe-debug/`). It documents the debug command channel (`Vibe --debug-cmd state|viewtree|screenshot|playPause|…`, debug builds only, defined in `Debug/DebugUtil.m`), both screenshot paths (the in-process snapshot helper cannot render `NSVisualEffectView` materials or Metal content — real `screencapture` is required for background/appearance checks), sandbox launch pitfalls (`open -a` vs raw argv, Xcode-run instances shadowing your build), and bundles scripts for window capture and pixel probing.

## Architecture

Vibe is a native macOS music player written in Objective-C/Objective-C++. Playback is built entirely on Apple frameworks (AVFAudio/AVAudioEngine + CoreAudio) with no third-party audio library — CoreAudio decodes MP3 and FLAC natively. There are no external dependencies; the vendored libraries below are compiled into the app target.

### Core Components

**Audio Playback Pipeline:**
- `AudioPlayer` drives an `AVAudioEngine` with a fresh `AVAudioPlayerNode` per track. State machine: `{Stopped, Playing, Paused, Loading}` — `Loading` covers the in-flight file open (reports `isPlaying`, zero position/duration). All engine mutation runs on a serial `dispatch_queue` (`com.vibe.audioplayer`, default QoS); UI-facing getters (`position`/`duration`/`isPlaying`) read state under an `os_unfair_lock` and never block. Two generation counters disambiguate async work: `_generation` for stale `scheduleSegment` completions, `_rampGeneration` for cancelling in-flight volume fades (stop/seek/skip/device-switch bump them first). All fades (~50ms pause/resume/skip ramps) are asynchronous — the queue never sleeps. On skip, the outgoing node is rerouted onto its own mixer input before its fade-out, because the incoming track's connect replaces the shared varispeed input and would otherwise hard-cut it. A last-valid-position cache preserves the playhead when the engine stops itself (device unplug/format change) before recovery can read it. Files are opened off-queue with a timeout so an undownloaded iCloud/Dropbox placeholder can't wedge playback; a slow open surfaces a loading state. The playlist's likely-next track is pre-opened (`prefetchTrack:`, called by the controller on every track start) and the parked `AVAudioFile` is consumed by the next `play:` of that path, so auto-advance/skip pays no file open. The engine is stopped when playback goes idle (releases the output device) and restarts lazily on the next play — the idle stop is deferred ~2 s (generation-cancelled by `startEngineAndPlayNode:`) so consecutive-track transitions reuse the running engine instead of paying an output-unit stop+start. The saved output device is resolved (UID first, name fallback) inside the async init on the player queue — device enumeration stays off the launch path's main thread. UI updates are dispatched back to the main thread via the `run_on_main_thread()` macro.
- `AudioTrack` is the data model for a track (URL, lazy-loaded duration, file hash for cache keys).
- `AudioTrackMetadata` extracts metadata (title, artist, album art, codec info) using TagLib. Results are persisted via `AudioTrackMetadataCache` (PINCache-backed, `NSSecureCoding`; failed parses are shown but never cached, via `parsedOK`). Art memory lifecycle: the disk cache stores only a 128px thumbnail JPEG; full-res art is decoded on demand (capped at 1024px via ImageIO) for the current track only and demoted (`discardDecodedAlbumArt`) when the track changes. Locks are never held across file I/O or image decode — cloud files can block reads indefinitely.
- `CoreAudioUtil` is a stateless set of raw HAL property accessors (device IDs, UIDs, names, output-channel checks). `AudioDeviceManager` (singleton) owns device-change listening: it registers CoreAudio listeners for the default output device and the device list at init (process lifetime, never removed) and fans out to weakly-held observers (`AudioDeviceManagerObserver`: `AudioPlayer`, `OutputDevicesMenuController`) on the main thread in the common run-loop modes — GCD main-queue blocks don't run during menu tracking, and the devices menu refreshes while open.

**Waveform System (two-layer architecture):**
- *Data layer* (`Audio/Waveform/`): `AudioWaveform` is a C++ data structure storing min/max float pairs per chunk. `AVFAudioWaveformLoader` (backed by `AVAudioFile`) generates waveform data asynchronously, handing immutable snapshots to the main thread for progressive rendering; cache lookups run on `AudioWaveformCache`'s serial loader queue but the open+decode runs on a global utility queue, because the `AVAudioFile` open has no cancellation point and can block for minutes on a cloud placeholder — off-queue it strands one worker instead of wedging every later track's waveform. `AudioWaveformCache` persists waveform data via PINCache.
- *BPM detection* (`Audio/Analysis/AudioBPMAnalyzer`, ObjC++ + Accelerate): rides the waveform loader's decode pass (no second file read) — power-spectrum spectral-flux onset envelope while streaming, then at end-of-file autocorrelation + harmonic comb over 60–200 BPM, with a time-domain phase-comb rescore of the top candidates (refining each candidate's fractional period against the envelope over a ≤40 s window) to resolve 2:1/3:2 metrical errors; returns 0 below a confidence gate (noise/speech/rubato). The result travels in `CodableAudioWaveform.bpm` (waveform cache v3), is delivered by `AudioWaveformCache` via `audioWaveformCache:didDetectBPM:`, and lands in `AudioTrack.detectedBPM` (transient). A file's own tempo tag (`AudioTrackMetadata.bpm`, TagLib PropertyMap "BPM": ID3 TBPM/MP4 tmpo/Vorbis BPM) wins over analysis; the BPM label under the codec label shows the winner scaled live by the pitch fader.
- *Rendering layer* (`Waveform/`): `AudioWaveformView` is a CALayer-based NSView that delegates rendering to strategy objects. It is a pure rendering surface: `MainPlayerController` owns the `AudioWaveformCache` (symmetric with `metadataCache`), requests loads, and forwards deliveries to the view via `showWaveform:` after resetting it with `prepareForWaveformLoad`. Renderer hierarchy: `AudioWaveformRenderer` (base) → `VibeDefaultWaveformRenderer` and `DetailedAudioWaveformRenderer`; `BasicAudioWaveformRenderer` and `OversamplingDetailedAudioWaveformRenderer` (x2/x4/x8 variants) subclass `DetailedAudioWaveformRenderer`. The default style is "Oversampling Detailed x4" (configurable in `AppSettings`).
- The C++ waveform types stay out of ObjC headers: `AudioWaveformCache.h` forward-declares `CodableAudioWaveform` instead of importing `AudioWaveform.h`, so the UI layer compiles as plain ObjC (.m).

**UI Architecture (AppKit/MVC):**
- `MainPlayerController` (NSWindowController) is the central coordinator. It implements `AudioPlayerDelegate`, `AudioWaveformViewDelegate`, `AudioWaveformCacheDelegate`, `AudioTrackMetadataCacheDelegate`, and `FileDropDelegate` — all in the class extension; the public header exposes only collaborators and actions. Two pieces are split out of the main file: menu validation and the delegate-built waveform-style submenu live in `MainPlayerController+Menus` (`NSMenuItemValidation` conformance is declared on that category), and the bare transport keys (Space/B/N/P/Tab) are handled by `TransportKeyMonitor`, a local keyDown monitor the controller owns. The debug command channel's extra surface lives in `MainPlayerController+Debug.h`. A 3 Hz dispatch timer drives the playback-position UI (`updatePlaybackUI`); the full `updateUI` runs on transport events and metadata deliveries. Metadata loading for a dropped playlist is deferred until playback starts (2 s fallback) so the first track plays immediately on large folder drops.
- `MainWindow` is a custom NSWindow that accepts file drag-and-drop (NSDraggingDestination) and supports small/large layout toggle. Dropped folders expand on a serial queue (`NSURLUtil`) so overlapping drops complete in submission order; files keep filesystem order (no sorting).
- `PlaylistManager` manages the track list as NSTableViewDataSource/Delegate with custom cells for track number, artwork thumbnail, title/artist, and duration.
- `OutputDevicesMenuController` populates the audio device selection menu from `AudioDeviceManager` (singleton) and, as an `AudioDeviceManagerObserver`, rebuilds the menu in place if devices change while it is open. Layout: "System Output (<default device>)" (tag -1, the default choice), a separator, then every output device; the checkmark tracks `AudioPlayer.currentlyRequestedAudioDeviceId`. An explicitly chosen device that disappears (mid-playback, while idle, or found missing at launch) falls back to System Output and the fallback is persisted.
- `About/` contains the About window: `AboutWindowController` plus `VectorBallsView`, an MTKView Metal animation (paused while the window is occluded).
- Programmatic layout, no nibs: `MainWindow` configures itself in `init` (borderless, frame autosave, drag-and-drop registration); the whole main-window view hierarchy lives in `MainPlayerContentView` (an `NSVisualEffectView` subclass exposing the subviews as readonly properties), which `MainPlayerController` adopts as its outlets in `buildContentInWindow:` (called from `init`; `windowDidLoad` is invoked manually since AppKit only fires it on the nib path). Playlist cell views are built in `PlaylistManager` (`makeCellViewWithIdentifier:`) and recycled through the table's normal reuse queue.
- App bootstrap (no main nib): `main.m` creates the `AppDelegate` (kept alive by a global — `NSApplication.delegate` is weak); `applicationWillFinishLaunching:` creates `MainPlayerController` (which owns its `OutputDevicesMenuController`) and installs the menu bar via `MainMenuBuilder`, which also backs the Open Recent submenu from `NSDocumentController.recentDocumentURLs`. Bare key equivalents must set `keyEquivalentModifierMask = 0` explicitly (`NSMenuItem` defaults to Command).

### Dependencies (vendored in `Vibe/ThirdParty/`)

- **taglib** (`ThirdParty/taglib/`, TagLib 2.2 subset, ~70 of 113 sources): audio metadata extraction. Only the formats the app plays are vendored — MPEG/ID3, MP4, FLAC, RIFF, plus the APE *tag* machinery MPEG files need and `ogg/xiphcomment` for FLAC comments. `TagLib::FileRef` is deliberately not used (its detection references every format parser); `AudioTrackMetadata.mm` has a `TagLibAudioFile` factory that mirrors FileRef's extension→content-sniff detection for the supported formats. When updating TagLib, re-copy the subset and let the linker report anything new.
- **PINCache** + **PINOperation** (`ThirdParty/PINCache/`, `ThirdParty/PINOperation/`): disk/memory caching for metadata and waveform data. `PINDiskCache.m` carries a per-file `-fobjc-arc-exceptions` compiler flag (the pod's Arc-exception-safe subspec did the same).

Framework-style imports (`<PINCache/...>`) resolve through target `HEADER_SEARCH_PATHS` entries pointing into `Vibe/ThirdParty/`.

### Logging

`LogError`/`LogWarn`/`LogInfo`/`LogDebug`/`LogTrace` macros (defined in `Vibe-Prefix.pch`) wrap Apple's unified logging (`os_log`) under subsystem `com.commonwealthrecordings.Vibe`. Info/debug messages are not persisted to the log store — stream them live with `/usr/bin/log stream --level debug --predicate 'subsystem == "com.commonwealthrecordings.Vibe"'` (use the full path; zsh has a `log` builtin).

### Key Patterns

- **Delegation** is used throughout: AudioPlayer → MainPlayerController, waveform views → controller, metadata cache → controller.
- **Singletons**: `AppSettings`, `AudioDeviceManager`.
- **File hashing**: `NSURL+Hash` provides the cache key for metadata and waveform data: `<size>-<mtime_us>-<sha1(path)>` from file attributes only (no content hash — cheap, but misses on rewrite or move).
- **ObjC++ (.mm files)**: Used only where C++ is actually needed — TagLib integration and the waveform data structures. Everything else (including the whole UI layer) is plain ObjC (.m); don't add C++ types to headers that ObjC files import.
- **Third-party sources** (`ThirdParty/`): `RSVerticallyCenteredTextFieldCell`, `taglib/`, `PINCache/`, `PINOperation/` — vendored code by other authors; don't restyle it.
- **Custom-drawn controls** (`Controls/`): the transport/close buttons (`GlyphButton`) and the playing-row indicator (`EqualizerIndicatorView`) draw CAShapeLayer/CALayer glyphs instead of asset-catalog images — resolution independent, state changes composited on the render server.

### Supported Audio Formats

MP3, MP2, FLAC, MP4/M4A, AAC, AIFF, WAV (all decoded natively by CoreAudio). OGG is not supported.

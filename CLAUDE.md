# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

Dev-tool dependencies (XcodeGen, jq) are declared in the `Brewfile` — install with `make setup` (runs `brew bundle`). `Vibe.xcodeproj` is generated from `project.yml` by XcodeGen and is **not** checked in — regenerate it after cloning, pulling, or editing `project.yml`:

```bash
xcodegen generate          # or: make project
```

Then build in Xcode (open `Vibe.xcodeproj`, `Vibe` scheme, ⌘R) or with `make build` from the command line. A **Debug** build is what the debug command channel needs — see Debugging / Verification.

Convenience wrappers (each runs `xcodegen generate` first and writes to `build/DerivedData`): `make build` (Release; `make build CONFIG=Debug` for debug) or `scripts/build.sh [Debug|Release]`.

To sign, notarize, or ship a build — the Developer ID path (`make release`) and the App Store path (`make appstore` / `make appstore-upload`), the shared App Store Connect API key, and the signing traps each script preflights — use the **`vibe-release` skill** (`.claude/skills/vibe-release/`). The two paths are not interchangeable; don't improvise from the scripts.

There is no package manager — all third-party code is vendored under `Vibe/ThirdParty/` and compiles as part of the app target (CocoaPods was removed; TagLib and PINCache are now in-tree). Editing `project.yml` (adding files, changing build settings) means running `xcodegen generate` again.

There are no unit tests in this project.

## Debugging / Verification

To launch, drive, inspect, or screenshot the app — anything involving verifying a change against the running app — use the **`vibe-debug` skill** (`.claude/skills/vibe-debug/`). It is the canonical reference for the debug command channel (`Vibe --debug-cmd <command>`, debug builds only, implemented in `Vibe/Debug/`): inspection dumps (player/UI state, view tree, menus, Now Playing, screenshot), transport/FX/UI driving, opening files, per-file waveform-cache control, and the BPM scan (`scan_bpm` / `scan-bpm.sh` — executed in the CLI process itself, so it needs no running app). It also covers the two screenshot paths and their blind spots, sandbox launch pitfalls, bundled capture/pixel-probing scripts, and log streaming + the launch-time build-provenance block. For test audio, use the generated files in `Assets/test_audio_files/` (gitignored); if missing, generate them with the skill's `generate-test-audio.sh` — don't synthesize ad-hoc files. The command list lives in the skill (and in the channel's own unknown-command reply), deliberately not here, so it can't drift.

## Architecture

Vibe is a native macOS music player written in Objective-C/Objective-C++. Playback is built entirely on Apple frameworks (AVFAudio/AVAudioEngine + CoreAudio) with no third-party audio library — CoreAudio decodes MP3 and FLAC natively. There are no external dependencies; the vendored libraries in `Vibe/ThirdParty/` are compiled into the app target.

### Subsystem map

Directory-scoped detail lives in nested `CLAUDE.md` files, loaded only when working under that directory — **read the relevant one before changing anything it covers**:

- **`Vibe/Audio/`** — the playback engine and audio data pipeline: `AudioPlayer` (AVAudioEngine; fresh player node + `AVAudioUnitVarispeed` per track; click-free crossfades, seeks, and fades; next-track prefetch; deferred idle engine stop), `AudioFX` (DJ performance effects on the master bus), TagLib metadata extraction + PINCache-backed cache with a two-stage playlist scan (`Metadata/`), the waveform *data* layer (`Waveform/`), BPM detection (`Analysis/`), and output-device management (`AudioDeviceManager`, `AudioPlayer+Devices`). The threading contract UI code relies on: all engine mutation runs on a serial player queue, the UI-facing getters (`position`/`duration`/`isPlaying`) never block, and delegate callbacks arrive on the main thread.
- **`Vibe/Waveform/`** — the waveform *rendering* layer: `AudioWaveformView` (a pure rendering surface — the controller owns the cache and forwards data), the renderer strategy hierarchy, and the shared `WaveformMorphEngine`.
- **`Vibe/Main Window/`** — `MainPlayerController` (the central coordinator: implements the player/waveform/metadata-cache delegate protocols, resolves all header rendering through one five-state `TrackDisplayState`, owns `TransportKeyMonitor` for the bare transport/FX keys), `NowPlayingController` (system Now Playing bridge), `MainWindow` (drag-and-drop, resize behavior), programmatic layout, and the Liquid Glass chrome.
- **`Vibe/Menu/`** — app bootstrap (`main.m`/`AppDelegate`), menu bar construction, default-player claim, View > Size, FX menu, output devices menu.
- **`Vibe/Playlist/`** — table structure vs. content split (`PlaylistTableView` / `PlaylistController`), Launch-Services burst opens.
- **`Vibe/Controls/`** — custom CALayer-drawn controls (`SymbolButton`, `EqualizerIndicatorView`, pitch fader).
- **`Vibe/ThirdParty/`** — the vendored TagLib subset and PINCache/PINOperation: what's included and why, update procedure, header-search-path wiring.
- **`Vibe/About/`** — About window (Metal animation).

### Cross-directory invariants

Each side is documented in its own directory's file; the coupling itself lives here:

- **BPM precedence**: a file's tagged tempo (`AudioTrackMetadata.bpm`) always wins over the analyzed one (`AudioTrack.detectedBPM`). The BPM label and the bar-based skip actions share this rule.
- **Async deliveries race track changes**: waveform/BPM/metadata cache deliveries can arrive after the track changed — receivers must match the delivered URL/track against the current one before applying it.
- **`AudioPlayer.stop` fires NO delegate callback** (it is not a track-end event, so it must never drive auto-advance) — the caller owns the UI reset. Track-end and skip-past-end both funnel through `didFinishPlaying:` instead.

### Logging

`LogError`/`LogWarn`/`LogInfo`/`LogDebug` macros (defined in `Vibe-Prefix.pch`) wrap Apple's unified logging (`os_log`) under subsystem `com.commonwealthrecordings.Vibe`. Streaming (info/debug aren't persisted) and the launch-time build-provenance block are covered in the **`vibe-debug` skill**.

### Key Patterns

- **No private APIs, ever** — this app ships in the Mac App Store. Don't call, override, or otherwise depend on undocumented selectors/classes/notifications (overriding a private method like `resignKeyAppearance` counts, even though it compiles without any private declaration). If a visual/behavioral goal has no public-API path (e.g. `NSGlassEffectView`'s inactive dimming has no public opt-out), accept the system behavior or redesign — don't reach for SPI.
- **Delegation** is used throughout: AudioPlayer → MainPlayerController, waveform views → controller, metadata cache → controller.
- **Singletons**: `AppSettings`, `AudioDeviceManager`.
- **File hashing**: `NSURL+Hash` provides the cache key for metadata and waveform data: `<size>-<mtime_us>-<sha1(path)>` from file attributes only (no content hash — cheap, but misses on rewrite or move).
- **ObjC++ (.mm files)**: Used only where C++ is actually needed — TagLib integration and the waveform data structures/renderers. Everything else (including the whole UI layer) is plain ObjC (.m); don't add C++ types to headers that ObjC files import.
- **Third-party sources** (`ThirdParty/`): vendored code by other authors; don't restyle it.

### Supported Audio Formats

MP3, MP2, FLAC, MP4/M4A, AAC, AIFF, WAV (all decoded natively by CoreAudio). OGG is not supported.

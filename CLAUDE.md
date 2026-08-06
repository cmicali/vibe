# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## Building

The `Brewfile` declares the dev tools, XcodeGen and jq. Install them with `make setup`, which runs `brew bundle`.

XcodeGen generates `Vibe.xcodeproj` from `project.yml`. The project file is **not** checked in, so regenerate it after cloning, after pulling and after every edit to `project.yml`:

```bash
xcodegen generate          # or: make project
```

Then build in Xcode — open `Vibe.xcodeproj`, pick the `Vibe` scheme, press ⌘R — or run `make build`. The debug command channel needs a **Debug** build; see Debugging and verification.

Two wrappers regenerate the project first and write to `build/DerivedData`: `make build` (Release, or `make build CONFIG=Debug`) and `scripts/build.sh [Debug|Release]`.

Use the **`vibe-release` skill** (`.claude/skills/vibe-release/`) to sign, notarize or ship a build. It covers the Developer ID path (`make release`), the App Store path (`make appstore` and `make appstore-upload`), the shared App Store Connect API key and the signing traps each script preflights. The two paths are not interchangeable, so do not improvise from the scripts.

There is no package manager. All third-party code is vendored under `Vibe/ThirdParty/` and compiles into the app target; CocoaPods is gone and TagLib and PINCache are now in-tree.

`make test` runs the unit tests, in `Tests/` at the repo root. They cover pure logic only — sample and geometry math, archive validation, formatting, precedence and fallback rules — and the bundle is host-less, so the suite needs no window server, no audio hardware and no running app. See `Tests/CLAUDE.md` before adding to it: sources under test are compiled into the test target rather than linked from the app, and a test file placed under `Vibe/` would be swept into the shipping binary.

Anything that has to be verified against the *running* app belongs in the debug command channel below, not in a unit test.

GitHub Actions runs the Debug and Release builds and the test suite on every push and pull request (`.github/workflows/build.yml`).

## Debugging and verification

Use the **`vibe-debug` skill** (`.claude/skills/vibe-debug/`) to launch, drive, inspect or screenshot the app — anything that verifies a change against the running app. It is the canonical reference for the debug command channel (`Vibe --debug-cmd <command>`, debug builds only, implemented in `Vibe/Debug/`): inspection dumps of player and UI state, the view tree, menus, Now Playing and screenshots; transport, FX and UI driving; opening files; per-file waveform-cache control; and the BPM scan (`scan_bpm` and `scan-bpm.sh`, which run in the CLI process itself and need no running app). It also covers the two screenshot paths and their blind spots, sandbox launch pitfalls, the bundled capture and pixel-probing scripts, log streaming and the launch-time build-provenance block.

For test audio, use the generated files in `Assets/test_audio_files/` (gitignored). If they are missing, generate them with the skill's `generate-test-audio.sh` rather than synthesizing your own.

The command list lives in the skill and in the channel's own unknown-command reply, deliberately not here, so it cannot drift.

## Architecture

Vibe is a native macOS music player written in Objective-C and Objective-C++. Playback rests entirely on Apple frameworks — AVFAudio's `AVAudioEngine` and CoreAudio — with no third-party audio library, because CoreAudio decodes MP3 and FLAC natively. The app has no external dependencies; the vendored libraries in `Vibe/ThirdParty/` compile into the app target.

### Subsystem map

Nested `CLAUDE.md` files hold the detail for each directory and load only when you work under it. **Read the relevant one before changing anything it covers.**

- **`Vibe/Audio/`** — the playback engine and the audio data pipeline. `AudioPlayer` runs `AVAudioEngine` with a fresh player node and `AVAudioUnitVarispeed` per track, and handles click-free crossfades, seeks and fades, next-track prefetch and a deferred idle engine stop. `AudioFX` puts the DJ performance effects on the master bus. `Metadata/` extracts tags with TagLib and caches them in PINCache behind a two-stage playlist scan. `Waveform/` is the waveform *data* layer, `Analysis/` detects BPM, and `AudioDeviceManager` and `AudioPlayer+Devices` manage output devices. UI code relies on the threading contract: every engine mutation runs on a serial player queue, the UI-facing getters (`position`, `duration`, `isPlaying`) never block, and delegate callbacks arrive on the main thread.
- **`Vibe/Waveform/`** — the waveform *rendering* layer: `AudioWaveformView`, a pure rendering surface whose controller owns the cache and forwards the data; the renderer strategy hierarchy; and the shared `WaveformMorphEngine`.
- **`Vibe/Main Window/`** — `MainPlayerController` is the central coordinator. It implements the player, waveform and metadata-cache delegate protocols, resolves all header rendering through a single five-state `TrackDisplayState`, and owns `TransportKeyMonitor` for the bare transport and FX keys. The directory also holds `NowPlayingController` (the system Now Playing bridge), `MainWindow` (drag-and-drop and resize behavior), the programmatic layout and the Liquid Glass chrome.
- **`Vibe/Menu/`** — app bootstrap (`main.m` and `AppDelegate`), menu bar construction, the default-player claim, View > Size, the FX menu and the output devices menu.
- **`Vibe/Playlist/`** — the split between table structure and content (`PlaylistTableView` and `PlaylistController`), plus Launch Services burst opens.
- **`Vibe/Controls/`** — controls drawn in CALayer rather than shipped as images: `SymbolButton`, `EqualizerIndicatorView` and the pitch fader.
- **`Vibe/ThirdParty/`** — the vendored TagLib subset and PINCache/PINOperation: what is included and why, how to update it and how the header search paths are wired.
- **`Vibe/About/`** — the About window and its Metal animation.

### Cross-directory invariants

Each side is documented in its own directory's file. The coupling itself lives here.

- **BPM precedence**: a file's tagged tempo (`AudioTrackMetadata.bpm`) always beats the analyzed one (`AudioTrack.detectedBPM`). The BPM label and the bar-based skip actions share the rule.
- **Async deliveries race track changes**: waveform, BPM and metadata cache deliveries can arrive after the track has changed, so a receiver must match the delivered URL or track against the current one before applying it.
- **`AudioPlayer.stop` fires no delegate callback.** It is not a track-end event, so it must never drive auto-advance, and the caller owns the UI reset. Track-end and skip-past-end both funnel through `didFinishPlaying:` instead.

### Logging

The `LogError`, `LogWarn`, `LogInfo` and `LogDebug` macros in `Vibe-Prefix.pch` wrap Apple's unified logging (`os_log`) under the subsystem `com.commonwealthrecordings.Vibe`. The **`vibe-debug` skill** covers streaming, which matters because info and debug are not persisted, and the launch-time build-provenance block.

### Key patterns

- **No private APIs, ever.** This app ships in the Mac App Store. Do not call, override or otherwise depend on undocumented selectors, classes or notifications — overriding a private method such as `resignKeyAppearance` counts, even though it compiles without any private declaration. When a visual or behavioral goal has no public-API path, as with `NSGlassEffectView`'s inactive dimming, accept the system behavior or redesign. Do not reach for SPI.
- **Delegation** runs throughout: `AudioPlayer` → `MainPlayerController`, waveform views → controller, metadata cache → controller.
- **Singletons**: `AppSettings` and `AudioDeviceManager`.
- **File hashing**: `NSURL+Hash` supplies the cache key for metadata and waveform data, `<size>-<mtime_us>-<sha1(path)>`, built from file attributes alone. Hashing no content keeps it cheap but misses a rewrite or a move.
- **ObjC++ (.mm files)** appear only where C++ is genuinely needed: the TagLib integration and the waveform data structures and renderers. Everything else, the whole UI layer included, is plain ObjC (.m), so keep C++ types out of headers that ObjC files import.
- **Third-party sources** in `ThirdParty/` are other authors' code. Do not restyle them.

### Supported audio formats

MP3, MP2, FLAC, MP4/M4A, AAC, AIFF and WAV, all decoded natively by CoreAudio. OGG is not supported.

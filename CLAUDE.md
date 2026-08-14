# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## Building

XcodeGen generates `Vibe.xcodeproj` from `project.yml`. The project file is **not** checked in, so regenerate it after cloning, after pulling and after every edit to `project.yml`:

```bash
xcodegen generate          # or: make project
```

Then build in Xcode — open `Vibe.xcodeproj`, pick the `Vibe` scheme, press ⌘R — or run `make build` (Release, or `make build CONFIG=Debug`; the debug command channel needs a **Debug** build, see Debugging and verification). `make build` and `scripts/build.sh [Debug|Release]` both regenerate the project first and write to `build/DerivedData`.

Use the **`vibe-release` skill** (`.claude/skills/vibe-release/`) to sign, notarize or ship a build. It covers the Developer ID path (`make release`), the App Store path (`make appstore-build` and `make appstore-upload-signed-build`), the shared App Store Connect API key and the signing traps each script preflights. The two paths are not interchangeable, so do not improvise from the scripts.

There is no package manager; all third-party code (TagLib, PINCache) is vendored under `Vibe/ThirdParty/` and compiles into the app target.

`make test` runs the unit tests, in `Tests/` at the repo root. They cover pure logic only, and the bundle is host-less — no window server, no audio hardware, no running app. **See `Tests/CLAUDE.md` before adding to it**: sources under test are compiled into the test target rather than linked from the app, and a test file placed under `Vibe/` would be swept into the shipping binary.

Anything that has to be verified against the *running* app belongs in the debug command channel below, not in a unit test.

## Debugging and verification

Use the **`vibe-debug` skill** (`.claude/skills/vibe-debug/`) to launch, drive, inspect or screenshot the app — anything that verifies a change against the running app. It is the canonical reference for the debug command channel (`Vibe --debug-cmd <command>`, debug builds only, implemented in `Vibe/Debug/`): inspection dumps of player and UI state, the view tree, menus, Now Playing and screenshots; transport, FX and UI driving; opening files; per-file waveform-cache control; and the BPM and key scans (`scan_bpm`/`scan-bpm.sh` and `scan_key`/`scan-key.sh`, which run in the CLI process itself and need no running app). It also covers the two screenshot paths and their blind spots, sandbox launch pitfalls, the bundled capture and pixel-probing scripts, log streaming and the launch-time build-provenance block.

Use the **`vibe-stress` skill** (`.claude/skills/vibe-stress/`, `make stress CORPUS=<folder>`) to drive the app *randomly, for hours, with oracles*: soak and endurance runs, leak and resource-growth hunting, race hunting under TSan, fuzzing the file-loading path, and shrinking a failing run to a repro. It builds on the debug channel above, so read `vibe-debug` first.

For test audio, use the generated files in `Assets/test_audio_files/` (gitignored). If they are missing, generate them with the skill's `generate-test-audio.sh` rather than synthesizing your own.

The command list lives in the skill and in the channel's own unknown-command reply, deliberately not here, so it cannot drift.

## Architecture

Vibe is a native macOS music player written in Objective-C and Objective-C++. Playback rests entirely on Apple frameworks — AVFAudio's `AVAudioEngine` and CoreAudio, no third-party audio library — because CoreAudio natively decodes every supported format: MP3, MP2, FLAC, MP4/M4A, AAC, AIFF and WAV. OGG is not supported.

### Subsystem map

Nested `CLAUDE.md` files hold the detail for each directory and load only when you work under it. **Read the relevant one before changing anything it covers.**

- **`Vibe/Audio/`** — playback engine, metadata, waveform data, BPM/key analysis, output devices.
- **`Vibe/Waveform/`** — waveform rendering: views, renderer strategies, morph engine.
- **`Vibe/Main Window/`** — `MainPlayerController` and the window; layout and Liquid Glass chrome live in that directory's `APPEARANCE.md`, its `CLAUDE.md` covering behavior.
- **`Vibe/Menu/`** — menu bar, plus the app bootstrap (`main.m` at the repo root, `AppDelegate` in `Common/`).
- **`Vibe/Playlist/`** — table structure vs content, Launch Services burst opens.
- **`Vibe/Controls/`** — CALayer-drawn controls.
- **`Vibe/ThirdParty/`** — the vendored TagLib subset and PINCache/PINOperation: what is included and why, how to update it.
- **`Vibe/Settings/`** — Settings window, `FolderAccessManager` sandbox bookmarks.

### Cross-directory invariants

Each side is documented in its own directory's file. The coupling itself lives here.

- **Tag-over-analysis precedence**: a file's tagged tempo (`AudioTrackMetadata.bpm`) always beats the analyzed one (`AudioTrack.detectedBPM`) — the BPM label and the bar-based skip actions share the rule — and the tagged key (`AudioTrackMetadata.key`) likewise beats `AudioTrack.detectedKey`. `AudioTrack.bpm` and `.key` are the single homes of both rules.
- **Async deliveries race track changes**: waveform, BPM, key and metadata cache deliveries can arrive after the track has changed, so a receiver must match the delivered URL or track against the current one before applying it.
- **A `VibeMusicalKey` of 0 is C major, not "none"**: every fresh holder must be set to `VibeMusicalKeyNone` (-1) explicitly, because a zero-filled ivar or a message to nil reads as tagged C major.
- **`AudioPlayer.stop` fires no delegate callback.** It is not a track-end event, so it must never drive auto-advance, and the caller owns the UI reset. Track-end and skip-past-end both funnel through `didFinishPlaying:` instead.

### Logging

The `LogError`, `LogWarn`, `LogInfo` and `LogDebug` macros in `Vibe-Prefix.pch` wrap Apple's unified logging (`os_log`) under the subsystem `com.commonwealthrecordings.Vibe`. The **`vibe-debug` skill** covers streaming, which matters because info and debug are not persisted, and the launch-time build-provenance block.

### Localization

**Every user-facing string is declared in `Vibe/Common/VibeStrings.h` and nowhere else.** Call sites use a `STR_*` macro and nothing more — no key, no English text, no translator comment inline.

Keys are symbolic and stable (`menu.file`, `label.bpm`), never the English text; the English lives in the macro's default value. **`make strings` after touching any UI string**; `make check-strings` fails when the catalog is stale. English is the source language; every other language is whatever the catalogs contain — don't hardcode the list anywhere, read it from `Resources/Localizable.xcstrings`.

**Display names are never identifiers** — the registry key, the `NSUserDefaults` value and the menu item's identifier stay separate from the localized label.

The machinery lives in the **`vibe-strings` skill** (`.claude/skills/vibe-strings/`): the `NSLS` registry conventions, the extraction pipeline and its `extractionState` rules, `InfoPlist.xcstrings`, translation terminology, testing a language, the pseudolocale audit, and the localized App Store product page. Read it before editing `VibeStrings.h`, the catalogs, or `scripts/extract-strings.sh`.

### Key patterns

- **No private APIs, ever.** This app ships in the Mac App Store. Do not call, override or otherwise depend on undocumented selectors, classes or notifications — overriding a private method such as `resignKeyAppearance` counts, even though it compiles without any private declaration. When a visual or behavioral goal has no public-API path, as with `NSGlassEffectView`'s inactive dimming, accept the system behavior or redesign. Do not reach for SPI.
- **Singletons**: `AppSettings`, `AudioDeviceManager`, and `AppStats` (lifetime usage counters — files/folders opened, seconds played — in `NSUserDefaults`; the open sinks and the player-delegate transitions feed it, `stop` and quit have no callback so `closeFile:` and `applicationWillTerminate:` flush by hand).
- **File hashing**: `NSURL+Hash` supplies the cache key for metadata and waveform data, `<size>-<mtime_us>-<sha1(path)>`, built from file attributes alone. Hashing no content keeps it cheap but misses a rewrite or a move.
- **ObjC++ (.mm files)** appear only where C++ is genuinely needed: the TagLib integration and the waveform data structures and renderers. Everything else, the whole UI layer included, is plain ObjC (.m), so keep C++ types out of headers that ObjC files import.
- **Comments only when required, and terse.** A comment earns its place by stating what the code cannot show: a trap, an ordering or threading constraint, a contract, a non-obvious why. Most code needs none. Never narrate what the next line does, justify a change, or record how something was verified or what it used to be — that history belongs in commits. If a comment runs long, it should be recording a hard-won trap; otherwise shorten it or simplify the code instead.
- **Third-party sources** in `ThirdParty/` are other authors' code. Do not restyle them.

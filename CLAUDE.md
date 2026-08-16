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

`make analyze` runs clang's static analyzer over **both app targets** and **fails on any finding outside `ThirdParty/`**. `project.yml` has had the analyzer's checks on all along (`CLANG_ANALYZER_NONNULL`, `CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION: YES_AGGRESSIVE`); the script and its CI job are what make them a gate rather than a setting nobody ran. It covered the macOS target alone until the iOS leg was added, which is why a few thousand lines of `Vibe/iOS/` and the shared subsystems' `iOS/` halves went unanalyzed for as long as they existed. Findings are not config-independent — keep it clean in Release, which is what CI checks and what ships.

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

- **`Vibe/Common/`** — what everything else is written in terms of: `AppSettings`, the localized-string registry, the prefix header, the declared document types, and the `VibeImage`/`VibeColor` platform aliases with the bounded image decode that builds one. No feature lives here.
- **`Vibe/Audio/`** — playback engine, FX, conversion, waveform data, BPM/key analysis. `Mac/Devices/` is the CoreAudio HAL output-device layer; `iOS/` is the AVAudioSession lifecycle and the engine-recovery category that answers its verdicts.
- **`Vibe/Audio/Metadata/`** — tags, the disk cache, the two-stage scan, embedded and folder art; opens with a map of the flow.
- **`Vibe/Audio/Waveform/`** — waveform *data*: generation, chunking, persistence. **`Vibe/Audio/Analysis/`** — tempo and key detection riding that decode pass.
- **`Vibe/Audio/Mac/Convert/`** — the FLAC encoder and the sandbox rungs its output has to climb.
- **`Vibe/System/`** — bridges to OS services that are neither audio engine nor app UI: the Now Playing / remote-command bridge and the cloud-file download progress monitor. Both platforms drive them.
- **`Vibe/Controls/`** — controls both platforms draw, which so far is `EqualizerIndicatorView`, the playing-row bars. A control earns a place here only when the two apps must draw the *same* one; `Mac/Controls/` keeps what is genuinely AppKit.
- **`Vibe/Playlist/`** — the model and the CUE/M3U readers, shared; `Mac/` is the table, structure vs content.
- **`Vibe/WaveformUI/`** — waveform *rendering*: renderer strategies and the morph engine, shared by both platforms; `Mac/` holds the `NSView` and its loading shimmer, `iOS/` the scrubber. Named apart from `Audio/Waveform/` deliberately — one makes the data, the other draws it.
- **`Vibe/Util/`** and **`Vibe/Debug/`** — the featureless helpers and the debug command channel (the `vibe-debug` skill covers the second). `Util/Mac/` and `Util/iOS/` are the first's platform halves; `Debug/` is the channel transport, dispatch, common verbs and load timing both targets compile, with `Debug/Mac/` and `Debug/iOS/` holding each platform's command table.
- **`Vibe/Mac/`** — the macOS app shell, one directory per piece, each with its own `CLAUDE.md` bar `About/`, which is one self-contained window:
  - **`App/`** — the application object and the app-wide services it owns: the open funnel and its burst coalescing, lifetime stats, and the sandbox grants (`FolderAccessManager`). The bootstrap starts at `main.m`, in the repo root.
  - **`MainWindow/`** — `MainPlayerController` and the window; layout and Liquid Glass chrome live in that directory's `APPEARANCE.md`, its `CLAUDE.md` covering behavior.
  - **`Menu/`** — the menu bar, one builder method per top-level menu.
  - **`Controls/`** — CALayer-drawn controls.
  - **`Settings/`** — the Settings window and its panes. The Files pane holds the folder-art setting; the sandbox bookmarks it lists belong to `Mac/App/`.
  - **`About/`** — the About window.
- **`Vibe/iOS/`** — the iPhone and iPad app shell (`VibeiOS` target), shaped like Apple Music: `PlaybackController`, the model everything else reads, and above it a tab shell whose home screen is the playlist, a mini player strip, and the full-screen now-playing card with the track pager in it. Plus the document-picker/security-scope/bookmark folder session. The iOS halves of the shared subsystems live under those subsystems, not here.
- **`Vibe/ThirdParty/`** — the vendored TagLib subset and PINCache/PINOperation: what is included and why, how to update it.

Adding a directory means adding an entry to `project.yml`; nothing globs it in.

**The directory is the platform boundary.** Every directory directly under `Vibe/` except `Mac/`, `iOS/`, and `ThirdParty/` is a shared subsystem, listed in both targets' sources in `project.yml`. Within any subsystem, `Mac/` and `iOS/` are the only platform markers: a path containing `Mac` compiles only into Vibe, a path containing `iOS` compiles only into VibeiOS, and a path containing neither compiles into both. No source entry may exclude a feature-named path. `make check-layout` enforces all of it.

So neither target needs a per-file exclude, and **a new file in a shared directory joins the iOS target automatically** — it must be AppKit-free or `TARGET_OS_OSX`-guarded. CI's `build-ios` job is what catches an AppKit leak.


### Cross-directory invariants

Each side is documented in its own directory's file. The coupling itself lives here.

- **Tag-over-analysis precedence**: a file's tagged tempo (`AudioTrackMetadata.bpm`) always beats the analyzed one (`AudioTrack.detectedBPM`) — the BPM label and the bar-based skip actions share the rule — and the tagged key (`AudioTrackMetadata.key`) likewise beats `AudioTrack.detectedKey`. `AudioTrack.bpm` and `.key` are the single homes of both rules. **Analysis itself is macOS-only** (below), so on iOS the analyzed half is simply always absent and the tagged half is the whole answer — which is why the rule lives on `AudioTrack` rather than at the display sites.
- **Embedded art beats folder art, and folder art costs as little as possible**: a file's own artwork always wins, and the cover beside it (`FolderArtResolver`, `Settings > Files`) fills in only for a file carrying none. It is resolved per *directory*, lazily, off the metadata scan's path entirely, and never pays for I/O of its own where the open was already doing some — a dropped folder's cover comes out of the expansion walk, a bulk open gets one listing per folder, and only a lone file probes, three stats at most; a folder with no cover, no grant or an unreadable one is settled for the resolver's bounded recent-directory history; and it is never persisted, because the metadata cache is keyed by the audio file's size and mtime, which a sidecar image cannot move. Folders the app holds no active grant for are left untouched rather than probed: an unresolved stored bookmark is not authority, and unasked-for background work must never raise a permission panel.
- **Three features are macOS-only, and each is switched off at one place rather than compiled out.** `FolderArtResolver` still builds for both targets, but `AudioTrackArtwork` leaves its `folderArt` handle nil on iOS, so every folder-art accessor is a message to nil — no cover, and no background load scheduled. The BPM and key analyzers still build for both, but the decode pass asks a `VibeWaveformAnalysisProvider` (`AudioWaveformLoader.h`) that only macOS installs, so on iOS neither analyzer is ever constructed. The DJ FX graph is off by the `enableFX:NO` the iOS player is created with. In all three the *setting* is macOS-only too (`AppSettings`), so there is no way for iOS to read a preference it cannot act on.
- **The 128px thumbnail is for list rows, and the iOS pager draws none of it.** Both platforms decode, hold and archive it (`AudioTrackArtwork`) — the mac playlist table's art cells, the iOS library rows and the iOS mini player all draw one. The iOS *page* deliberately does not: it shows the full-size decode with nothing standing in for it, since 128px is fine under the blur but visibly soft in the art card, and installing it first only buys a swap to sharp a moment later.
- **A track is named on screen in one place**: `AudioTrack.displayTitle` and `.displayArtist` decide whether a row shows the tagged title with the artist beside it or the filename-derived single line, so the mac playlist row and header and the iOS page, track sheet and search sheet cannot spell the same track four ways — which they did. A nil `displayArtist` means there is no second line to draw, not an empty one.
- **Async deliveries race track changes**: waveform, BPM, key and metadata cache deliveries can arrive after the track has changed, so a receiver must match the delivered URL or track against the current one before applying it.
- **A `VibeMusicalKey` of 0 is C major, not "none"**: every fresh holder must be set to `VibeMusicalKeyNone` (-1) explicitly, because a zero-filled ivar or a message to nil reads as tagged C major.
- **`AudioPlayer.stop` fires no delegate callback.** It is not a track-end event, so it must never drive auto-advance, and the caller owns the UI reset. Track-end and skip-past-end both funnel through `didFinishPlaying:` instead.

### Vocabulary

One word per pattern; a new synonym is a bug. `make check-vocabulary` enforces the mechanical half.

| Term | Means exactly | Never used for |
| --- | --- | --- |
| `generation` | staleness counter stamped on async work; a mismatch on completion means "superseded, drop it". Always spelled `<protectedThing>Generation`, never bare | batch ordering, handles |
| `claim` | single-flight ownership of shared work (roles: owner, waiter) | OS-level role registration — that is `registration` |
| `waiter` | a parked callback delivered exactly once when its event settles | polling loops |
| `token` | opaque handle proving a request is still current (the debug CLI's lexer tokens and Darwin `notify` tokens are separate, standard usages) | counters |
| `intent` | the desired end state a request must land in | the request itself |
| `snapshot` | immutable copy handed across threads | live references |
| `sequence` | delivery order within one generation | anything else |
| `embedded` | art carried in the audio file's own tag | the folder's cover |
| `cover` | the sidecar image beside the audio file | embedded art |

**Suffixes.** `Vibe` prefixes C-linkage symbols, which have no namespace; ObjC classes never carry it. Header-only files of `static inline` logic — the app's testable seams — are `*Rules.h` when they return a decision and `*Math.h` when they return a number in the problem's units; nothing else. Behavior added to a foreign class is a category (`NSURL+Hash`, `PINCache+VibeAudioCache`), never a free function taking that class as its first argument.

**`Coordinator` is deliberately generic** and names three different contracts: `PlaybackRequestCoordinator` is request identity, `MetadataParseCoordinator` is single-flight ownership, `OpenRequestCoordinator` is ordered delivery. A fourth needs saying which it is.

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
- **Comments only when required, and terse.** A comment earns its place by stating what the code cannot show: a trap, an ordering or threading constraint, a contract, a non-obvious why. Most code needs none. Never narrate what the next line does, justify a change, or record how something was verified or what it used to be — that history belongs in commits. If a comment runs long, it should be recording a hard-won trap; otherwise shorten it or simplify the code instead. **Mark those with `TRAP:`** — one spelling, so `grep -rn 'TRAP:' Vibe` is the list of things that bite, and `make check-vocabulary` fails on any other spelling.
- **Third-party sources** in `ThirdParty/` are other authors' code. Do not restyle them.

# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

Vibe is a native music player for macOS (`Vibe` target) and iOS (`VibeiOS` target), written in Objective-C and Objective-C++. Playback is Apple frameworks only — `AVAudioEngine` and CoreAudio, no third-party audio library. Formats: MP3, MP2, AAC, AIFF/AIF, WAV/WAVE/BWF, FLAC, M4A, MP4 (`NSURLUtil.m`'s extension set). OGG is not supported.

## Building

`Vibe.xcodeproj` is generated from `project.yml` by XcodeGen and is **not** checked in. Regenerate after cloning, after pulling and after every edit to `project.yml`:

```bash
xcodegen generate        # or: make project
```

| Command | What it does |
| --- | --- |
| `make build [CONFIG=Debug]` | macOS app; Release by default. Regenerates the project, writes to `build/DerivedData`. |
| `make build-ios [CONFIG=Debug]` | iOS app, generic simulator destination, unsigned. Exactly what CI's `build-ios` job runs. |
| `make run` / `make install` | Launch; copy into `/Applications`. |
| `make clean` | Removes `build/` and the generated project. |

Debug builds are what the debug command channel needs — it compiles out of Release entirely.

Releases go through the **`vibe-release` skill** (`.claude/skills/vibe-release/`): the Developer ID path (`make release`), the App Store path (`make appstore-build`, `make appstore-upload-signed-build`), the shared App Store Connect API key, and the signing traps each script preflights. The two paths are not interchangeable — do not improvise from the scripts.

There is no package manager. TagLib and PINCache/PINOperation are vendored under `Vibe/ThirdParty/` and compile into both app targets.

## Checks

Everything below runs in CI (`.github/workflows/build.yml`) and can be run locally.

| Command | Gate |
| --- | --- |
| `make test` | Unit tests (`Tests/`, `VibeTests` target, always Debug). Pure logic only, host-less. **Read `Tests/CLAUDE.md` before adding to it.** |
| `make test-summary` | Markdown pass/fail table from the last `make test`. |
| `make analyze CONFIG=Release` | clang static analyzer over **both** app targets; fails on any finding outside `ThirdParty/`. Findings are config-dependent — keep Release clean, which is what CI checks. |
| `make check-layout` | The layout rule below. |
| `make check-vocabulary` | The mechanical vocabulary rules below. |
| `make check-strings` | Fails when `Resources/Localizable.xcstrings` is stale against the source. |
| `make check-translations` | Fails when any key is missing a catalog language. Both release paths run it. |
| `make appstore-validate-copy` | App Store copy completeness and caption fit. |

Anything that must be verified against the *running* app belongs in the debug command channel, not in a unit test.

## Debugging and verification

Use the **`vibe-debug` skill** (`.claude/skills/vibe-debug/`) to launch, drive, inspect or screenshot either app. It is the canonical reference for the debug command channel (`Vibe --debug-cmd <command>`, debug builds only, `Vibe/Debug/`): state dumps, the view tree, menus, Now Playing, screenshots, transport/FX/UI driving, file opening, waveform-cache control, and the `scan_bpm`/`scan_key` analyzers that run in the CLI process with no app. It also covers the iOS simulator loop (`launch-ios.sh`, `debug-ios.sh`, `drive-ios.sh`), log streaming, and the launch-time build-provenance block.

Use the **`vibe-stress` skill** (`make stress CORPUS=<folder>`, `make torture PLAYLIST=<folder>`) for soak runs, leak and resource-growth hunting, TSan race hunting, fuzzing the file-loading path, and shrinking a failing run to a repro. It builds on the debug channel — read `vibe-debug` first.

Test audio: `Assets/test_audio_files/` (gitignored). If missing, generate with the `vibe-debug` skill's `generate-test-audio.sh` rather than synthesizing your own.

The command list lives in the skill and in the channel's own unknown-command reply, deliberately not here, so it cannot drift.

## Layout: the directory is the platform boundary

`project.yml` lists **one source entry per directory** — a new directory needs a new entry, nothing globs it in. Within that:

- Every directory directly under `Vibe/` except `Mac/`, `iOS/` and `ThirdParty/` is a **shared subsystem**, listed in both targets' sources.
- Inside any subsystem, `Mac/` and `iOS/` are the only platform markers: a path containing `Mac` compiles only into `Vibe`, a path containing `iOS` only into `VibeiOS`, a path containing neither into both.
- No source entry may exclude a feature-named path. The only excludes allowed are `**/.DS_Store`, `**/*.md`, `Mac/**`, `iOS/**`, plus `**/Info.plist` on a shell directory and a fixed list under `ThirdParty/`.

Consequences: **a new file in a shared directory joins the iOS target automatically**, so it must be AppKit-free or `TARGET_OS_OSX`-guarded. A shared source may not `#import` a header that only one platform's tree has, unguarded — Xcode's project-wide headermap resolves it by basename whatever the target membership, so it would compile and then fail at runtime or link.

`make check-layout` enforces all four assertions; CI's `build-ios` job catches an AppKit leak.

## Subsystem map

Nested `CLAUDE.md` files hold the detail and load only when you work under that directory. **Read the relevant one before changing anything it covers.**

**Documentation follows the same platform boundary as the code.** A shared subsystem's own `CLAUDE.md` covers only what both platforms have; anything specific to one platform belongs in a `CLAUDE.md` under that subsystem's `Mac/` or `iOS/` directory, beside the code it describes — so `Audio/CLAUDE.md` is the engine, `Audio/Mac/Devices/CLAUDE.md` is the HAL layer, and `Audio/iOS/CLAUDE.md` is the audio session. A `.md` file is excluded from every source entry in `project.yml`, so one can be added to any directory without touching the build.

- **`Vibe/Common/`** — what everything else is written in terms of: `AppSettings`, `VibeStrings.h`, the prefix header, `DocumentTypes`, the `VibeImage`/`VibeColor` platform aliases and the bounded image decode. No feature lives here.
- **`Vibe/Audio/`** — playback engine, FX, waveform data, BPM/key analysis, conversion. `Mac/Devices/` is the CoreAudio HAL output-device layer, `Mac/Convert/` the FLAC encoder, `iOS/` the AVAudioSession lifecycle and engine recovery.
- **`Vibe/Audio/Metadata/`** — tags, the disk cache, the two-stage scan, embedded and folder art.
- **`Vibe/Audio/Waveform/`** — waveform *data*: generation, chunking, persistence. **`Vibe/Audio/Analysis/`** — tempo and key detection riding that decode pass.
- **`Vibe/System/`** — bridges to OS services that are neither audio engine nor app UI: Now Playing / remote commands, cloud download progress, cloud file materialization. Both platforms drive them.
- **`Vibe/Controls/`** — controls both platforms draw (`EqualizerIndicatorView`). A control earns a place here only when both apps draw the *same* one.
- **`Vibe/Playlist/`** — the model and the CUE/M3U readers, shared; `Mac/` is the table.
- **`Vibe/WaveformUI/`** — waveform *rendering*: renderer strategies and the morph engine, shared; `Mac/` the `NSView`, `iOS/` the scrubber. Named apart from `Audio/Waveform/` deliberately — one makes the data, the other draws it.
- **`Vibe/Util/`** — featureless helpers, with `Mac/` and `iOS/` halves. **`Vibe/Debug/`** — the debug channel: shared transport, dispatch and common verbs, with `Mac/` and `iOS/` command tables.
- **`Vibe/Mac/`** — the macOS app shell, one directory per piece: `App/` (application object, open funnel, sandbox grants, stats), `MainWindow/` (`MainPlayerController`; layout and chrome are that directory's `APPEARANCE.md`), `Menu/`, `Controls/`, `Settings/`, `About/`.
- **`Vibe/iOS/`** — the iPhone/iPad app shell: `PlaybackController` (the model), a tab shell, mini player, and the full-screen now-playing card. The iOS halves of shared subsystems live under those subsystems, not here.
- **`Vibe/ThirdParty/`** — vendored TagLib subset and PINCache/PINOperation.

## Cross-directory guarantees

A **guarantee** is a condition the code must keep true, written once so a new call site can be checked against it. Each side is documented in its own directory; the coupling lives here.

- **Tag-over-analysis precedence.** A file's tagged tempo (`AudioTrackMetadata.bpm`) beats the analyzed one (`AudioTrack.detectedBPM`); tagged key likewise beats `detectedKey`. `AudioTrack.bpm` and `.key` are the single homes of both rules. Analysis is macOS-only, so on iOS the tagged half is the whole answer.
- **Embedded art beats folder art.** A file's own artwork always wins; a cover beside it (`FolderArtResolver`) fills in only for a file carrying none. Folder art is resolved per *directory*, lazily, off the metadata scan's path entirely, and is never persisted — the metadata cache is keyed by the audio file's size and mtime, which a sidecar image cannot move. A folder the app holds no *active* grant for is left untouched rather than probed: unasked-for background work must never raise a permission panel.
- **Three features are macOS-only, each switched off at one place rather than compiled out.** `FolderArtResolver` builds for both targets, but `AudioTrackArtwork` leaves its `folderArt` handle nil on iOS, so every folder-art accessor is a message to nil. The BPM and key analyzers build for both, but the decode pass asks a `VibeWaveformAnalysisProvider` (`AudioWaveformLoader.h`) that only macOS installs. The DJ FX graph is off by the `enableFX:NO` the iOS player is created with. All three settings are macOS-only in `AppSettings`, so iOS cannot read a preference it cannot act on.
- **The 128px thumbnail is for list rows.** Both platforms decode, hold and archive it (`AudioTrackArtwork`) — the mac playlist's art cells, the iOS library rows, the iOS mini player. The iOS now-playing *page* deliberately draws none of it: it shows the full-size decode with nothing standing in for it.
- **A track is named on screen in one place.** `AudioTrack.displayTitle` and `.displayArtist` decide whether a row shows tagged title + artist or the filename-derived single line. A nil `displayArtist` means there is no second line to draw, not an empty one.
- **The open the user is waiting on outranks every background read that would download a file.** On a file-provider folder the scarce thing is the provider's transfer. Each shell **defers** the metadata sweep until the picked track's open settles (`scheduleDeferredMetadataLoad`, both platforms), and while an open is in flight the cache's **cloud lane is held** (`setCloudParsesHeld:`, set and cleared with the download monitor). The rule and its lanes are `Audio/Metadata/CLAUDE.md`; the call sites are each shell's `+PlayerEvents`.
- **Async deliveries race track changes.** Waveform, BPM, key and metadata deliveries can arrive after the track has changed, so a receiver must match the delivered URL or track against the current one before applying it.
- **A `VibeMusicalKey` of 0 is C major, not "none".** Every fresh holder must be set to `VibeMusicalKeyNone` (-1) explicitly — a zero-filled ivar or a message to nil reads as tagged C major.
- **`AudioPlayer.stop` fires no delegate callback.** It is not a track-end event, so it must never drive auto-advance, and the caller owns the UI reset. Track-end and skip-past-end both funnel through `didFinishPlaying:`.

## Vocabulary

One word per pattern; a new synonym is a bug.

| Term | Means exactly | Never used for |
| --- | --- | --- |
| `guarantee` | a condition the code must keep true, written once so a new call site can be checked against it. Never the word "invariant" | a `*Rules.h` decision, or an API `contract` |
| `generation` | staleness counter stamped on async work; a mismatch on completion means "superseded, drop it". Always spelled `<protectedThing>Generation`, never bare | batch ordering, handles |
| `claim` | single-flight ownership of shared work (roles: owner, waiter) | OS-level role registration — that is `registration` |
| `waiter` | a parked callback delivered exactly once when its event settles | polling loops |
| `token` | opaque handle proving a request is still current (the debug CLI's lexer tokens and Darwin `notify` tokens are separate, standard usages) | counters |
| `intent` | the desired end state a request must land in | the request itself |
| `snapshot` | immutable copy handed across threads | live references |
| `sequence` | delivery order within one generation | anything else |
| `embedded` | art carried in the audio file's own tag | the folder's cover |
| `cover` | the sidecar image beside the audio file | embedded art |

**Suffixes.** `Vibe` prefixes C-linkage symbols, which have no namespace; ObjC classes never carry it. Header-only files of `static inline` logic — the app's testable seams — are `*Rules.h` when they return a decision and `*Math.h` when they return a number in the problem's units; nothing else.

Behavior added to a foreign class is a category (`NSURL+Hash`, `PINCache+VibeAudioCache`), never a free function taking that class as its first argument. The one exception is `Common/PlatformImage.h`'s bounded decode, which constructs an `NSImage` or a `UIImage` depending on target and so has no single class to hang on.

**`Coordinator` is deliberately generic** and names three different contracts: `PlaybackRequestCoordinator` is request identity, `MetadataParseCoordinator` is single-flight ownership, `OpenRequestCoordinator` is ordered delivery. A fourth needs saying which it is.

`make check-vocabulary` enforces five mechanical rules, and it is the authority on what is checkable:

1. No bare `_generation` ivar — spell it `<protectedThing>Generation`.
2. No `DefaultAppClaim` — OS role registration is `registration`.
3. Every header-only `static inline` file with no `.m`/`.mm` beside it must be `*Rules.h` or `*Math.h`, unless it is on the script's allowlist of non-seam headers (`AudioPlayerInternal.h`, `HelperMacros.h`, `MusicalKey.h`, `PlaybackIntent.h`, `VibeStrings.h`).
4. **No `#if DEBUG` in a shipping header.** Debug surface is a declaration-only category under `Vibe/Debug/`. There is no allowlist. A debug-only property ships as a pointer; debug-only *state* belongs to a debug-only object the shipping class holds (`VibeManualRenderPump`).
5. The trap marker is spelled `TRAP:` and nothing else, so `grep -rn 'TRAP:' Vibe` is the complete list of things that bite.

## Logging

`LogError`, `LogWarn`, `LogInfo`, `LogDebug` in `Vibe-Prefix.pch` wrap `os_log` under the subsystem `com.commonwealthrecordings.Vibe`. Info and debug are **not persisted**, so they must be streamed live — see the `vibe-debug` skill.

## Localization

**Every user-facing string is declared in `Vibe/Common/VibeStrings.h` and nowhere else.** Call sites use a `STR_*` macro and nothing more — no key, no English text, no translator comment inline.

Keys are symbolic and stable (`menu.file`, `label.bpm`), never the English text; the English lives in the macro's default value. **`make strings` after touching any UI string**; `make check-strings` fails when the catalog is stale. English is the source language; read the language list from `Resources/Localizable.xcstrings` rather than hardcoding it.

**Display names are never identifiers** — the registry key, the `NSUserDefaults` value and a menu item's identifier stay separate from the localized label.

The **`vibe-strings` skill** is the reference for the `NSLS` registry conventions, the extraction pipeline and its `extractionState` rules, `InfoPlist.xcstrings`, translation terminology, the pseudolocale audit and the localized App Store product page. Read it before editing `VibeStrings.h`, the catalogs or `scripts/extract-strings.sh`.

## Key patterns

- **No private APIs, ever.** This app ships in the Mac App Store. Do not call, override or depend on undocumented selectors, classes or notifications — overriding a private method such as `resignKeyAppearance` counts, even though it compiles without any private declaration. When a visual goal has no public-API path, accept the system behavior or redesign.
- **Deployment targets are macOS 14.0 and iOS 26.0.** `CLANG_WARN_UNGUARDED_AVAILABILITY: YES_AGGRESSIVE` is on, so anything newer than the floor needs an `@available` guard — the Liquid Glass chrome is guarded on macOS 26 with a pre-26 fallback.
- **Singletons**: `AppSettings`, `AudioDeviceManager` (macOS), `AppStats` (macOS), `FolderAccessManager` (macOS), `FolderArtResolver`, `Formatters`.
- **File hashing**: `NSURL+Hash.cacheKey` supplies the cache key for metadata and waveform data — `<size>-<mtime_us>-<sha1(resolved path)>`, from file attributes alone. It resolves symlinks first (`attributesOfItemAtPath:` does not traverse them) and returns nil rather than a degenerate key when the stat fails. Hashing no content keeps it cheap but misses a rewrite or a move.
- **ObjC++ (.mm files)** appear only where C++ is genuinely needed: the TagLib integration, the waveform data structures and the renderers. Keep C++ types out of headers that plain ObjC files import.
- **Comments only when required, and terse.** A comment earns its place by stating what the code cannot show: a trap, an ordering or threading constraint, a contract, a non-obvious why. Most code needs none. Never narrate what the next line does, justify a change, or record how something was verified or what it used to be — that history belongs in commits. Mark hard-won traps with `TRAP:`.
- **Third-party sources** in `ThirdParty/` are other authors' code. Do not restyle them.

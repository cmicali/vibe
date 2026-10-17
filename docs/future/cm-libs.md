# Future: cm_libs, the shared toolbox

**Status: planned 2026-10-17, nothing moved.** The toolbox repo is [cmicali/cm_libs](https://github.com/cmicali/cm_libs), and its `docs/plan.md` holds the same plan from the toolbox's side. Everything in Vibe that another app could use moves to `cm_libs`, a public toolbox of small libraries for macOS and iOS apps. That starts with the audio engine, waveform data and drawing, and the caches, and goes on to file loading, tags, playlists, controls and app plumbing. Vibe and another app consume it. Each app takes only the pieces it wants. The vendored third-party code becomes pieces of its own, so an app can take TagLib or dr_flac without the engine. Non-audio pieces join later.

The other app is closed source and is never named in this repository or in `cm_libs`. Call it "another app".

## What came before

- A plan of 2026-10-08 put two static library targets inside this repository, with the other app as extra targets here. The other app now has its own repository, so that shape is out. Its cut list survives below.
- A plan of 2026-10-09 in the toolbox repository (then called PlaybackKit) chose a separate public repo, a git submodule, a shared XcodeGen spec of static framework targets, a `PBK` prefix rename of every symbol on the move, and `git filter-repo` for history. It rejected a Swift package until outside users matter. The repo, the submodule, the shared spec, the order and the history carry stand. Four of its decisions change below.
- PR #294 built `Packages/WaveformCore`, a Swift package of pure C++17 with its own tests, and compiled its sources straight into both apps. That is the first toolbox piece, and it proves a standalone build is the boundary check.

## What blocks the split, measured on `main`

Only five files in the moving code read `AppSettings`: one in folder art, four in the waveform views and theme. The real blockers:

1. **The prefix header.** `Vibe-Prefix.pch` gives every file the `Log*`, `VIBE_REALTIME_*` and signpost macros. A standalone build has none.
2. **Strings.** `AudioErrorRules.h` maps error codes to `STR_ERROR_*`. `AudioTrack` has two labels. Every renderer returns a localized style name. One site each in Metadata, Loading and Util.
3. **Debug imports in production code.** Seven unguarded (`AudioLoadTiming.h` and the work tally) and eight under `#if DEBUG`.
4. **`Audio/` and `Loading/` import each other.** One shared header of open rules and the loader's typed handle make the cycle. Seams 14 and 15 below untangle it.
5. **One shell reach.** `FolderArtResolver` imports the mac's `FolderAccessManager`.
6. **Platform halves** are categories on `AudioPlayer` that the core calls under `TARGET_OS_OSX`. They cannot be a separate module.

## Decisions

1. **The name is `cm_libs`. The prefix for new code is `CMM`.** `CM` alone is CoreMedia's.
2. **No rename.** Moves are pure `git mv`, with history carried by `git filter-repo`. The `Vibe` C prefix stays. The unprefixed classes (`AudioPlayer`, `AudioFileHandle`, `WaveformView`) are listed by a check. A scripted prefix is a later PR if ever wanted. The rename the earlier plan folded into the move would touch 441 names, 678 files and 88 of #294's 111 files.
3. **#294 merged here first.** The waveform data moves once.
4. **Pieces are cut by job, not by Vibe's directories.** Split a piece when that saves a consumer a dependency. Merge parts that only work together. The rules and the full list of about thirty pieces are in the cm_libs plan.
5. **Compile in tree.** Apps add `cm_libs` as a git submodule, include `cm_libs.yml`, and list the templates they want. The sources compile into the app exactly as today. Static libraries and SwiftPM are later switches, with their triggers below.

## The build shape

**Git submodule, sources compiled in tree, source lists owned by the toolbox as XcodeGen target templates.**

Today every engine file is a translation unit of the app target. There is no LTO. Cross-file inlining happens only through headers. The per-file `-O3` on dr_libs, r8brain, PFFFT and WaveformCore applies in every configuration. The audio tests compile four render files at `-O2` and force `VIBE_VERBOSE_LOGGING=1`. `VibeTests` links an incomplete `AudioTrackMetadata` decoy. Compiling in tree keeps all of that unchanged, so the run-time cost is zero by construction.

| Shape | Run time | What it costs |
| --- | --- | --- |
| Templates, compiled in | none, same objects | nothing |
| Static library targets in the shared spec | none, with `-ObjC` | a library is built once per project, so the tests cannot have their `-O2` and verbose copy, and the decoy duplicates a class |
| SwiftPM linking | Debug slower | Xcode builds a package with its own settings, Debug unoptimized, `-O3` only as `unsafeFlags`, which a git-URL consumer may not use |

**The acceptance test, for Phase 0 and every move.** `perf.py compare main main` records the no-op band of retired instructions. Then `perf.py compare <before> <after>` must sit inside it. Then `make test-audio` wall time before and after, within noise, which catches a Debug optimization loss.

### The pieces

The pieces, their groups and their dependencies are listed once, in [cm_libs' plan](https://github.com/cmicali/cm_libs/blob/main/docs/plan.md). In short, the toolbox holds these groups:

| Group | Pieces | Mostly from |
| --- | --- | --- |
| `core/` | Common, Graphics | `Util/`, `Common/Platform*`, the prefix header's macros |
| `files/` | FileLoading, RemoteFiles, HTTP, ShareLinks, SandboxAccess, DiskCache | `Loading/`, `Mac/App/FolderAccessManager`, the cache helper |
| `audio/` | DSP, Analysis, Decode, Meter, FX, OutputDevices, Player | `Audio/` |
| `media/` | Tags, Metadata, Playlists, FolderScan, PlayQueue | `Audio/Metadata/`, the shared half of `Playlist/`, `iOS/Search/FileSearchIndex` |
| `waveform/` | Waveform, WaveformStyles, WaveformLoading, WaveformView | `Packages/WaveformCore`, `Audio/Waveform/`, `WaveformUI/` |
| `ui/` | Controls | `Controls/`, `Mac/Controls/` |
| `system/` | NowPlaying, AppOpening, Updates | `NowPlaying/`, `Mac/App/OpenBurstCoalescer`, `OpenRequestCoordinator`, the Sparkle wiring |
| `dev/` | DebugChannel, iOSDriver | `Debug/Channel/`, `Tests/iOSDriver/` |
| `third_party/` | each vendored library, Sparkle included | `ThirdParty/` |

What stays in Vibe: both shells, the playlist row (`AudioTrack`), the playlist table, settings, strings, themes, the link store, Dropbox, Convert to FLAC, the debug verbs and their command tables, and the widget.

### The shared spec

One `targetTemplate` per piece, with this repo's flag anchors moved in unchanged. Platform halves use `excludes: ["${excludedPlatform}/**"]`, filled from the consumer's `templateAttributes`. One project setting, the verbose-logging switch, which Vibe maps from `VIBE_BETA_DEBUG` and the tests set to 1. The log subsystem reads the main bundle identifier.

Vibe's `project.yml` afterward includes the spec. Each app target lists its templates and `templateAttributes`. The `Vibe/Audio`, `Vibe/WaveformUI` and `Vibe/Controls` entries go. The four vendored flag anchors and their 22 entries go, as do the eleven TagLib header search paths. `Vibe/Loading` keeps only `iOS/Dropbox` and the link store. `Vibe/ThirdParty` goes.

### The boundary check

Every test bundle in the toolbox's own project sets `USE_HEADERMAP: NO`, `ALWAYS_SEARCH_USER_PATHS: NO`, `GCC_PREFIX_HEADER: ""`, and header search paths of only its piece and its declared dependencies. A stray `#import "AppSettings.h"` then fails to compile there. `Packages/WaveformCore/Package.swift` stays as the one standalone package.

### Imports, not a prefix header

Under compile-in there is one prefix header per app target, so a prefix header per piece cannot exist. The 33 engine files that use the macros import `CMMMacros.h` explicitly. Vibe's pch keeps its framework imports and imports that header, so app code is unchanged.

### When to switch shapes later

- **To static library targets:** when the test targets stop compiling production sources and a second consumer target lands in one project. Template becomes `type: library.static`, apps change `templates:` to `dependencies:`, and `OTHER_LDFLAGS: -ObjC` goes on every app and test target.
- **To SwiftPM:** only for outside users. A product with `unsafeFlags` cannot be consumed by git URL, so the `-O3` cost is measured first. A `Package.swift` also needs whole-file `#if TARGET_OS_OSX` guards in the 34 platform-half files. Do not add them now.

## The cuts, as PRs on `main`, before any library exists

Each PR is mergeable alone and leaves every check passing. Smallest first. After PR 12 this grep returns nothing, which is the library rule stated as a check:

```
grep -rln 'AppSettings\|AppTheme\|VibeStrings.h\|FolderAccessManager\|PlaylistFile.h\|DebugWireFormat' \
  Vibe/Audio Vibe/Loading Vibe/WaveformUI Vibe/Controls | grep -v Loading/iOS/Dropbox
```

| # | PR | The cut | Shape and precedent |
| --- | --- | --- | --- |
| 1 | Seam parser | `Debug/Seams/AudioLoadingConfiguration+Debug.m` imports the channel's `DebugWireFormat.h` for one integer parser. | A local parser beside `VibeParseAudioLoadingDuration`. A seam imports nothing from `Channel/` or `Verbs/`. |
| 2 | Playlist extensions | `Loading/Net/RemotePlaceholderStore.m` imports `PlaylistFile.h` for `isPlaylistExtension:`. | Move the three extension tests into `Common/PlayableExtensions`. |
| 3 | Metadata cache root | `AudioTrackMetadataCache` passes `rootPath:nil` and cannot be given one. | `initWithLoadingConfiguration:rootPath:` plus a public `initWithRootPath:`, mirroring `AudioWaveformCache`. Both caches then take a root. |
| 4 | Folder art providers | `FolderArtResolver -init` reads `useFolderArt` and calls `FolderAccessManager`. | Delete the reads. `-init` uses the injectable `initWithEnabledProvider:accessProvider:` with the iOS defaults. `AppDelegate` installs both beside the `FolderWalk` handlers. |
| 5 | AudioTrack strings | `STR_LABEL_TRACK_ARTIST_TITLE` is `"%1$@ - %2$@"` in all 30 languages. `STR_LABEL_CUE_TRACK` is translated. | Retire the first key and join with a literal. The second becomes a class property `cueTrackTitleFormat`, pushed at launch by each app delegate. TRAP: do not route it through the CUE reader, because `PlaylistFile` persists `cueTitle` into the session. |
| 6 | `Common/StringRules.h` | `VibeStatusForPlayError`, `LinkStore`'s 26 `STR_LINK_*`, eight renderer `+displayName` overrides and the registry's two name methods. | One header-only file in Vibe, the one place a library's code or identifier becomes a `STR_*`. Precedent `SettingsRules.h`. `styleIdentifiers` returns a stable order and each shell sorts by name. |
| 7 | Formatters stays in Vibe | `AudioTrack.durationString`, `AudioTrackMetadata.fileInfoLine`, both views' `accessibilityLabel`, `Formatters.percentString:`. | Delete `durationString`. `fileInfoLineForMetadata:` moves to `Formatters`. Shells set the label where they build the view. A small `WaveformAccessibility.h` formats the percent. |
| 8 | Identifier macros | `SETTINGS_VALUE_WAVEFORM_*` in `AppSettings.h` are identifiers the registry and theme own. | Theme, band and palette identifiers to `WaveformTheme.h`, style identifiers to `WaveformRendererRegistry.h`. Names unchanged. |
| 9 | `WaveformTheme+Settings` | `themeForAppTheme:` and `themeForSettings:widget:` map Vibe's stores onto the theme. | A category in `Vibe/Common/WaveformTheme+Settings`, precedent `AppSettings+Themes`. `WaveformTheme` then imports only `PlatformColor.h`. |
| 10 | Mac `WaveformView` pushed | Nine `AppSettings` reads. | Pushed properties the renderer already has, a `dragSeeks` BOOL, and a `themeProvider` block. One shell method `applyWaveformSettings` pushes everything. One new live-effect bit for the drag popup. Precedent `AudioPlayer.declick`. |
| 11 | iOS scrubber pushed | Six reads. | `syncWaveformStyle` takes the resolved identifier. `centered` and `drawsPlayheadLine` pushed. A `themeProvider` block replaces three `themeForSettings:` calls. |
| 12 | `CMMMacros.h` | The pch's macro body is what the libraries use. | Move it to `CMMMacros.h` beside `HelperMacros.h`. The pch keeps the framework imports and imports it. `VibeWorkTally` moves beside it. |

**The seams between pieces.** These come from the import graph of the shared code on `origin/main`, and follow the twelve cuts above.

| # | Seam | Today | Fix |
| --- | --- | --- | --- |
| 13 | `AudioTrack` splits | Nine shared areas import the playlist row. | A small value naming a file and an optional frame window moves to Decode, with its source and cache keys. The player, both caches, the CUE reader, the folder walk, Now Playing and the play queue take that value or a URL. The row keeps the tags, the analyzed tempo and key, the display names and the rule that tags beat analysis. This is the largest cut, and most of the others build on it. |
| 14 | `AudioFileOpenRules.h` splits | It holds the open's delivery states, path spelling and the mount read-ahead rules. Four areas import it. | Each part goes to the piece that owns it. |
| 15 | The loader's handle | Its opener is already a block, but it is typed as `AudioFileHandle`. It also calls `[AudioTrack invalidateMemoizedCacheKeys]`. | The handle becomes a small protocol for interrupting reads and holding a stream. The call becomes a handler block. |
| 16 | TagLib and artwork | The TagLib wrapper returns an artwork extractor and reads remote ranges through the materializer. | Tags returns art bytes and takes a byte-range reader. |
| 17 | The waveform decode's analyzers | The loader builds the tempo and key analyzers itself. | It takes observers of each mono block, and the app attaches the analyzers. |
| 18 | CUE and M3U | The readers return `AudioTrack` rows. | They return records, and Vibe mints rows from them. |
| 19 | Now Playing and the play queue | Both hold `AudioTrack`. | Now Playing takes a snapshot value, and the queue holds values. |
| 20 | The link store | It mixes share-link rules with track naming and strings. | The rules and the client move. The store stays. |
| 21 | The shell pieces | The folder-grant panel, the pitch fader and the drawn controls read strings, fonts and `Formatters`. The Sparkle wiring reads the beta setting. | The app pushes each one in. |

These seams add four small types: the file-and-window value, the handle protocol, the decode observer block and the playlist record. Each one replaces a dependency on an app class.

**Moves with its users, no source change:** `Util/StallWatch`, `NSString+CPPStrings`, `VibeWeakProxy`, `NSView+DarkMode`, `UIView+DarkMode`, `HelperMacros.h`, the platform aliases, `PlayableExtensions`, the debug seams, simulators and `AudioLoadTiming`. Convert is wholly `Vibe/Mac/Convert/` and stays. `AudioFileHandle`'s writing half stays in the engine. `VibeWidget/` is untouched.

## The moves, in order

The moves are planned in [cm_libs' plan](https://github.com/cmicali/cm_libs/blob/main/docs/plan.md). Each move is a pull request there, plus one here that bumps the submodule and deletes what moved. Each is `git mv` only, and each passes the acceptance test. In order:

1. Phase 0: the license and eight build experiments. The repo rename and its docs are done (2026-10-17).
2. Phase 1: the cuts and seams above, here.
3. The pilot, DSP with the varispeed.
4. `third_party/`.
5. `core/`, and the portable pieces: DSP, Analysis, Tags, Playlists, ShareLinks.
6. `files/`.
7. The waveform data.
8. `audio/` and `media/`.
9. The waveform drawing and `ui/Controls`. The other app can start after this.
10. `system/` and `dev/`.
11. Docs.

### What changes in this repo's tooling

- `scripts/checks/check-layout.sh` reads included specs, substitutes `${excludedPlatform}`, extends its import assertion to the submodule, and gains three assertions: no `#import "../` from `Vibe/` into the submodule, no toolbox file imports a header whose only home is under `Vibe/` or `Tests/`, and a fast failure with the remedy when the submodule is not initialized.
- `make project` runs `git submodule update --init --recursive` first. The worktree line in the root `AGENTS.md` gains the same.
- `.github/workflows/build.yml` sets `submodules: recursive` on every checkout.
- `perf.py` copies `templates` and `templateAttributes` in `tool_spec()`, globs the submodule in `features()`, and runs `submodule update --init` in each worktree. Same line in `scripts/bench/build-version.sh`. Old refs keep working.
- `VibeTests` and `VibeAudioTests` keep their hand lists until each piece's tests move. The production paths change prefix and the vendored entries become template references.

## TRAPs

- **A checkout without the submodule compiles nothing from the toolbox and fails late.** `make project`, `perf.py` and CI all run or request `submodule update`. `check-layout` fails fast when the spec is missing.
- **YAML anchors do not cross `include:` files.** Every `*dr-libs-flags` reference becomes a template reference.
- **The headermap hides a crossed boundary.** Only the toolbox's headermap-off bundles make the compiler say no.
- **A per-piece prefix header cannot exist under compile-in.** Explicit imports are the only shape that works in every consumer.
- **`xcodegen dump` leaves templates unresolved.** `perf.py` must copy them or the benchmark tool silently builds without the engine.
- **A static library drops category-only objects unless the app links with `-ObjC`.** The first thing to add if a template ever becomes a library target.
- **`scripts/build/analyze.sh` drops findings by the substring `/ThirdParty/`.** The toolbox's vendored code sits under `third_party/`, so the gate must also drop `/third_party/` before that move lands, or it fails on TagLib's findings.

## Budget

Most of the shared code and its tests leave this repo. Deleted or unified in what remains: the vendored flag anchors and their entries, eleven header search paths, three source entries, the prefix header's macro body, eight renderer name overrides and two registry methods, one link-error table and `VibeStatusForPlayError` consolidated into one header, `AudioTrack.durationString`, two accessibility overrides and a duplicated constant, one catalog key, eighteen settings reads, and two imports. New here: `Common/StringRules.h`, `Common/WaveformTheme+Settings`, `WaveformUI/WaveformAccessibility.h`, one live-effect bit. New types: the four the seams add, each argued above. The two hand-kept test source lists are not consolidated yet. The tests must keep compiling production sources for verbose logging, the `-O2` render path and the decoy. They shrink as each piece's tests move.

**Not done here.** Artwork keeps handing out `NSImage` and `UIImage`. WaveformStyles stays Objective-C++ until its later rewrite into portable C++. Windows support and the move of Vibe's release and test scripts into the toolbox come later, as cm_libs' plan says.

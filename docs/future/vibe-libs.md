# Future: vibe-libs, the shared toolbox

**Status: planned 2026-10-17. On 2026-10-18 Phase 0 was answered and the pilot moved the varispeed and the realtime-effects brackets.** The toolbox repo is [cmicali/vibe-libs](https://github.com/cmicali/vibe-libs), and its `docs/plan.md` holds the same plan from the toolbox's side. Everything in Vibe that another app could use moves to `vibe-libs`, a public toolbox of small libraries for macOS and iOS apps. That starts with the audio engine, waveform data and drawing, and the caches, and goes on to file loading, tags, playlists, controls and app plumbing. Vibe and another app consume it. Each app takes only the pieces it wants. The vendored third-party code becomes pieces of its own, so an app can take TagLib or dr_flac without the engine. Non-audio pieces join later.

The other app is closed source and is never named in this repository or in `vibe-libs`. Call it "another app".

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

1. **The name is `vibe-libs`. The prefix for new code is `CMM`.** `CM` alone is CoreMedia's.
2. **No rename.** Moves are pure `git mv`, with history carried by `git filter-repo`. The `Vibe` C prefix stays. The unprefixed classes (`AudioPlayer`, `AudioFileHandle`, `WaveformView`) are listed by a check. A scripted prefix is a later PR if ever wanted. The rename the earlier plan folded into the move would touch 441 names, 678 files and 88 of #294's 111 files.
3. **#294 merged here first.** The waveform data moves once.
4. **Extraction first, and the playback and waveform path first.** A move changes no API, language, or platform. Portable rewrites, new tag fields, and other redesigns are separate work. The playback and waveform path moves first, and the other app builds its first slice on it. Every other piece moves when a second app needs it.
5. **Pieces are cut by job, not by Vibe's directories.** Split a piece when that saves a consumer a dependency. Merge parts that only work together. The rules and the full list of about thirty pieces are in the vibe-libs plan.
6. **Compile in tree.** Apps add `vibe-libs` as a git submodule, include `vibe-libs.yml`, and list the templates they want. The sources compile into the app exactly as today. Static libraries and SwiftPM are later switches, with their triggers below.

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

The pieces, their groups and their dependency map are listed once, in [vibe-libs' plan](https://github.com/cmicali/vibe-libs/blob/main/docs/plan.md). The map is derived from this repo's imports by vibe-libs' `scripts/plan/derive-deps.py`. Rerun it after each cut here. In short, the toolbox holds these groups:

| Group | Pieces | Mostly from |
| --- | --- | --- |
| `core/` | Common, Graphics | `Util/`, `NSURL+Hash`, `Common/Platform*`, the prefix header's macros |
| `files/` | FileLoading, RemoteFiles, HTTP, ShareLinks, SandboxAccess, DiskCache | `Loading/`, `Mac/App/FolderAccessManager`, the cache helper |
| `audio/` | AudioTypes, DSP, Analysis, Decode, Meter, FX, OutputDevices, Player | `Audio/`, `Common/PlayableExtensions` |
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
| 7 | Formatters stays in Vibe | `AudioTrackMetadata.fileInfoLine`, both views' `accessibilityLabel`, `Formatters.percentString:`. | `fileInfoLineForMetadata:` moves to `Formatters`. Shells set the label where they build the view. A small `WaveformAccessibility.h` formats the percent. |
| 8 | Identifier macros | `SETTINGS_VALUE_WAVEFORM_*` in `AppSettings.h` are identifiers the registry and theme own. | Theme, band and palette identifiers to `WaveformTheme.h`, style identifiers to `WaveformRendererRegistry.h`. Names unchanged. |
| 9 | `WaveformTheme+Settings` | `themeForAppTheme:` and `themeForSettings:widget:` map Vibe's stores onto the theme. | A category in `Vibe/Common/WaveformTheme+Settings`, precedent `AppSettings+Themes`. `WaveformTheme` then imports only `PlatformColor.h`. |
| 10 | Mac `WaveformView` pushed | Nine `AppSettings` reads. | Pushed properties the renderer already has, a `dragSeeks` BOOL, and a `themeProvider` block. One shell method `applyWaveformSettings` pushes everything. One new live-effect bit for the drag popup. Precedent `AudioPlayer.declick`. |
| 11 | iOS scrubber pushed | Six reads. | `syncWaveformStyle` takes the resolved identifier. `centered` and `drawsPlayheadLine` pushed. A `themeProvider` block replaces three `themeForSettings:` calls. |
| 12 | `CMMMacros.h` | The pch's macro body is what the libraries use. | Move it to `CMMMacros.h` beside `HelperMacros.h`. The pch keeps the framework imports and imports it. `VibeWorkTally` moves beside it. |

**The seams between pieces.** These come from the import graph of the shared code on `origin/main`, and follow the twelve cuts above.

| # | Seam | Today | Fix |
| --- | --- | --- | --- |
| 13 | The playable-item protocol | Nine shared areas import the playlist row. | A small protocol gives an item's file, frame window, source key, and disk key. `AudioTrack` adopts it and stays in Vibe, moving to `Vibe/Playlist/` as the row it is, with its tags, analyzed tempo and key, display names, and the rule that tags beat analysis. The player, Metadata, and the waveform cache take `id` of the protocol and hand back the same object, so object identity survives. The queue takes any object (seam 19). The source key, path and window, names the same audio for shared work, claims, and late deliveries, and does not change with the file's contents. The disk key, `NSURL+Hash.cacheKey` with the window appended for a waveform, names one version of the file for persisted entries. The player's submission identity stays its own. |
| 14 | `AudioFileOpenRules.h` splits | It holds the open's delivery states, path spelling and the mount read-ahead rules. Four areas import it. | Each part goes to the piece that owns it. |
| 15 | The loader's handle | Its opener is already a block, but it is typed as `AudioFileHandle`. It also calls `[AudioTrack invalidateMemoizedCacheKeys]`. | The handle becomes a small protocol for interrupting reads and holding a stream. The call becomes a handler block. |
| 16 | TagLib and artwork | The TagLib wrapper returns an artwork extractor and reads remote ranges through the materializer. | Tags returns art bytes and takes a byte-range reader. |
| 17 | The waveform decode's analyzers | The loader builds the tempo and key analyzers itself. | It takes observers of each mono block, and the app attaches the analyzers. |
| 18 | CUE and M3U | The readers return `AudioTrack` rows. | They return records, and Vibe mints rows from them. |
| 19 | The play queue, then Now Playing | Both hold `AudioTrack`. `Playlist` relies on object identity: two entries for one file are two entries. | The queue holds opaque entries and keeps object identity. Its lookups by file and by window take two key blocks the app passes when it makes the queue: Vibe passes the URL and the source key. It stops minting rows: replacing one row takes an object Vibe already made with `replacementAtURL:`, and replacing every row of a file takes a block Vibe implements with it. The queue keeps the indexes, both shuffle orders, and the observer events. So the queue depends on nothing. Now Playing takes a snapshot value when it moves. |
| 22 | Metadata's holder protocol | The metadata loader reads an item's installed metadata and installs results through `AudioTrack (Internal)`'s `installMetadataIfUnresolved:` and `deliverIfMetadataStillInstalled:usingBlock:`. | Metadata declares those three operations as its own protocol, and `AudioTrack` adopts it with the methods it has. The check and the install stay atomic in the row. Decode's playable-item protocol stays free of metadata. |
| 20 | The link store | It mixes share-link rules with track naming and strings. | The rules and the client move. The store stays. `LinkClient` also stops importing `LinkStore`. |
| 23 | The walk's file handler | FolderWalk notes cover-art candidates itself, through Metadata's `FolderArtRules.h`. | FolderScan reports each walked file to a handler, and Metadata's folder art installs it, as FolderWalk's other handlers are installed at launch. |
| 21 | The shell pieces | The folder-grant panel, the pitch fader and the drawn controls read strings, fonts and `Formatters`. The Sparkle wiring reads the beta setting. | The app pushes each one in. |

These seams add small types: the playable-item protocol, Metadata's holder protocol, the handle protocol, the decode observer block, and later the playlist record. Each one replaces a dependency on an app class.

**Only the cuts the playback and waveform path needs come first:** 1, 3, 4, 6 to 17, 19's queue half, and 22. Cut 2 and seam 20 wait for RemoteFiles and ShareLinks, seams 18 and 23 for Playlists and FolderScan, 19's Now Playing half for NowPlaying, and seam 21 for the shell pieces. Cut 5 is needed only if `AudioTrack` ever moves.

**`CodableAudioWaveform` stays with the waveform data**, in the Waveform piece's Objective-C++ part beside the unchanged C++ package. Both views, the style registry, both shells, and the widget publisher hold it, so moving it to the cache would make drawing depend on Decode and FileLoading.

**Two ownership rules from the import graph.** The morph engine stays with the renderers in WaveformStyles, since they drive it. `AudioPlayer+Devices`, `+BitPerfect`, and `+Recovery` read the player's private state, so they go to `Player/Mac` and `Player/iOS`. The device manager, `CoreAudioUtil`, the format rules, and the iOS session controller name the player only in comments, so they form OutputDevices.

**Moves with its users, no source change:** `Util/StallWatch`, `NSString+CPPStrings`, `VibeWeakProxy`, `NSView+DarkMode`, `UIView+DarkMode`, `HelperMacros.h`, the platform aliases, `PlayableExtensions`, the debug seams, simulators and `AudioLoadTiming`. Convert is wholly `Vibe/Mac/Convert/` and stays. `AudioFileHandle`'s writing half stays in the engine. `VibeWidget/` is untouched.

## The moves, in order

The moves are planned in [vibe-libs' plan](https://github.com/cmicali/vibe-libs/blob/main/docs/plan.md). Each move is a pull request there, plus one here that bumps the submodule and deletes what moved. Each is `git mv` only, and each passes the acceptance test. In order:

1. Phase 0: the license and eight build experiments. The repo rename and its docs are done (2026-10-17).
2. The pilot, DSP with the varispeed, after cut 12 alone. The pilot moves `CMMMacros.h` to vibe-libs with it, as the first file of `core/Common`, and Vibe's prefix header imports it from the submodule.
3. The cuts and seams the playback and waveform path needs, here.
4. The path moves: `third_party/` without Sparkle, `core/`, FileLoading and DiskCache, `audio/`, Tags, Metadata and PlayQueue, then `waveform/` and the indicators. The other app's first slice starts after this.
5. The tag fields: album, album artist, genre, year, track and disc numbers, composer, the compilation flag, and a release identifier. The metadata archive's version moves, which costs every Vibe user one re-parse, so it ships in an announced release. Vibe reads none of the fields.
6. Every other piece, when a second app needs it.

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

Most of the shared code and its tests leave this repo. Deleted or unified in what remains: the vendored flag anchors and their entries, eleven header search paths, three source entries, the prefix header's macro body, eight renderer name overrides and two registry methods, one link-error table and `VibeStatusForPlayError` consolidated into one header, `AudioTrack.durationString`, two accessibility overrides and a duplicated constant, one catalog key, eighteen settings reads, and two imports. New here: `Common/StringRules.h`, `Common/WaveformTheme+Settings`, `WaveformUI/WaveformAccessibility.h`, one live-effect bit. New types: the small ones the seams add, each argued above. The two hand-kept test source lists are not consolidated yet. The tests must keep compiling production sources for verbose logging, the `-O2` render path and the decoy. They shrink as each piece's tests move.

**Not done here.** Artwork keeps handing out `NSImage` and `UIImage`. WaveformStyles stays Objective-C++ until its later rewrite into portable C++. Windows support and the move of Vibe's release and test scripts into the toolbox come later, as vibe-libs' plan says.

# Future: cm_libs, the shared toolbox

**Status: planned 2026-10-17, nothing moved.** The toolbox repo is [cmicali/cm_libs](https://github.com/cmicali/cm_libs), and its `docs/plan.md` holds the same plan from the toolbox's side. Vibe's audio engine, waveform data, waveform drawing and caches move to `cm_libs`, a public toolbox of small libraries for macOS and iOS apps. Vibe and another app consume it. Each app takes only the pieces it wants. The vendored third-party code becomes pieces of its own, so an app can take TagLib or dr_flac without the engine. Non-audio pieces join later.

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
4. **`Audio/` and `Loading/` import each other.** They are one piece.
5. **One shell reach.** `FolderArtResolver` imports the mac's `FolderAccessManager`.
6. **Platform halves** are categories on `AudioPlayer` that the core calls under `TARGET_OS_OSX`. They cannot be a separate module.

## Decisions

1. **The name is `cm_libs`. The prefix for new code is `CMM`.** `CM` alone is CoreMedia's.
2. **No rename.** Moves are pure `git mv`, with history carried by `git filter-repo`. The `Vibe` C prefix stays. The unprefixed classes (`AudioPlayer`, `AudioTrack`, `WaveformView`) are listed by a check. A scripted prefix is a later PR if ever wanted. The rename the earlier plan folded into the move would touch 441 names, 678 files and 88 of #294's 111 files.
3. **#294 merges here first.** The waveform data then moves once.
4. **Compile in tree.** Apps add `cm_libs` as a git submodule, include `cm_libs.yml`, and list the templates they want. The sources compile into the app exactly as today. Static libraries and SwiftPM are later switches, with their triggers below.

## The build shape

**Git submodule, sources compiled in tree, source lists owned by the toolbox as XcodeGen target templates.**

Today every engine file is a translation unit of the app target. There is no LTO. Cross-file inlining happens only through headers. The per-file `-O3` on dr_libs, r8brain and PFFFT, and `-Os` on WaveformCore, apply in every configuration. The audio tests compile four render files at `-O2` and force `VIBE_VERBOSE_LOGGING=1`. `VibeTests` links an incomplete `AudioTrackMetadata` decoy. Compiling in tree keeps all of that unchanged, so the run-time cost is zero by construction.

| Shape | Run time | What it costs |
| --- | --- | --- |
| Templates, compiled in | none, same objects | nothing |
| Static library targets in the shared spec | none, with `-ObjC` | a library is built once per project, so the tests cannot have their `-O2` and verbose copy, and the decoy duplicates a class |
| SwiftPM linking | Debug slower | Xcode builds a package with its own settings, Debug unoptimized, `-O3` only as `unsafeFlags`, which a git-URL consumer may not use |

**The acceptance test, for Phase 0 and every move.** `perf.py compare main main` records the no-op band of retired instructions. Then `perf.py compare <before> <after>` must sit inside it. Then `make test-audio` wall time before and after, within noise, which catches a Debug optimization loss.

### The layout

One directory per piece. One template per piece. One test bundle per piece. A new piece is one directory, one template, one test bundle and one `AGENTS.md`.

```
cm_libs/
  AGENTS.md  README.md  LICENSE  docs/plan.md
  cm_libs.yml        the shared spec: settingGroups and one targetTemplate per piece
  project.yml        the toolbox's own project: the spec plus one test bundle per piece
  Makefile  .github/workflows/ci.yml  scripts/checks/check-pieces.sh
  Common/            CMMMacros.h (log, realtime, signposts), HelperMacros.h, PlatformTypes, PlatformImage, PlatformColor, VibeWorkTally
  Audio/             Vibe/Audio minus Waveform/ and Analysis/, with Loading/ (Claim, Transfer, Net, PlaceholderFiles) inside it
  WaveformData/      AudioWaveform and its codable form; WaveformCore/ as #294 built it
  Analysis/          AudioBPMAnalyzer, AudioKeyAnalyzer, MusicalKey.h, AnalysisFramerMath.h
  FX/                AudioFX, AudioVarispeed, FadeMath.h
  WaveformUI/        WaveformTheme, Renderers/, Mac/, iOS/, Controls/
  ThirdParty/        one piece each: taglib, dr_mp3, dr_flac, dr_wav, r8brain, PINCache with PINOperation, ogg, vorbis
  Tests/             mirrors the pieces
```

| Piece | Imports from | Third-party |
| --- | --- | --- |
| Common | nothing | none |
| ThirdParty/* | nothing | itself |
| Analysis | `MusicalKey.h`, which moves with it | none |
| FX | `FadeMath.h`, `HelperMacros.h` | none |
| WaveformData | Common, WaveformCore | none |
| Audio | Common, FX, Analysis, WaveformData | taglib, dr_*, r8brain, PINCache, ogg, vorbis |
| WaveformUI | WaveformData (`AudioWaveform.h` only), Common | none |

The waveform loader and cache stay in `Audio/Waveform/`. Only the waveform type is `WaveformData`. So WaveformUI depends on the data alone, and a UI-only consumer links no player. Keep the vendored code under a path containing `/ThirdParty/`, because `scripts/build/analyze.sh` drops findings by that substring.

### The shared spec

One `targetTemplate` per piece, with this repo's flag anchors moved in unchanged. Platform halves use `excludes: ["${excludedPlatform}/**"]`, filled from the consumer's `templateAttributes`. One project setting, the verbose-logging switch, which Vibe maps from `VIBE_BETA_DEBUG` and the tests set to 1. The log subsystem reads the main bundle identifier.

Vibe's `project.yml` afterward includes the spec. Each app target lists its templates and `templateAttributes`. The `Vibe/Audio`, `Vibe/WaveformUI` and `Vibe/Controls` entries go. The four vendored flag anchors and their 22 entries go, as do the eleven TagLib header search paths. `Vibe/Loading` stays for `iOS/Dropbox`. `Vibe/ThirdParty` keeps Sparkle only.

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

**Moves with its users, no source change:** `Util/StallWatch`, `NSString+CPPStrings`, `VibeWeakProxy`, `NSView+DarkMode`, `UIView+DarkMode`, `HelperMacros.h`, the platform aliases, `PlayableExtensions`, the debug seams, simulators and `AudioLoadTiming`. Convert is wholly `Vibe/Mac/Convert/` and stays. `AudioFileHandle`'s writing half stays in the engine. `VibeWidget/` is untouched.

## The moves, in order

Each move is a PR in `cm_libs` plus a PR here that bumps the submodule and deletes the moved directory. Each is `git mv` only. Each passes the acceptance test.

**Phase 0: the repository and the experiments.** The repo is renamed to `cm_libs` and its docs rewritten (done 2026-10-17). Choose the license. Run eight throwaway experiments and record the answers in the toolbox plan: paths in an included spec resolve relative to it; a template can nest templates and `${excludedPlatform}` substitutes; a template's header search paths concatenate with the target's; a headermap-off bundle fails a stray import; `xcodegen dump` keeps included templates; the pilot passes the perf acceptance; `.package(path:)` accepts `unsafeFlags` and `.package(url:)` refuses; `actions/checkout` with `submodules: recursive` reaches all five CI jobs.

**Phase 1: the twelve cuts here.** Done when the grep returns nothing.

**Phase 2: the pilot, FX with the varispeed.** The smallest piece with no dependencies. It proves the submodule, the template, the toolbox CI, `make project` running `submodule update --init`, worktrees, Vibe's CI checkout, `perf.py`'s worktree build, and the `pitch` benchmark unchanged.

**Phase 3: the vendored pieces.** Each with its flag anchor and its notes on Vibe's fixes. The apps' binaries are byte-identical after. `THIRD-PARTY-NOTICES.md` splits.

**Phase 4: Analysis and Common.** `perf.py --analyze` proves tempo and key exact.

**Phase 5: WaveformData.** After #294 merges. `Packages/WaveformCore` moves whole with its `Package.swift`.

**Phase 6: the engine.** `Vibe/Audio` with `Loading/` inside it, the caches, the debug seams and simulators. Its tests move with it. `VibeAudioTests` becomes a toolbox test bundle.

**Phase 7: WaveformUI and Controls.** Verified with `vibe-debug` screenshots on both platforms and the `ui-waveform` benchmark pictures byte-identical.

**Phase 8: docs.** Each `AGENTS.md` moves with its directory. Engine-only guarantees move to the toolbox's root doc. This repo's root keeps the guarantees that span app and engine, each naming its toolbox side. `docs/audio-quality.md` and the component charts move. `docs/architecture.md` gains one section on what comes from the toolbox.

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
- **Keep `/ThirdParty/` in the vendored path** or `analyze.sh` fails on TagLib's findings.

## Budget

About 39,000 lines of engine and its tests leave this repo. Deleted or unified in what remains: the vendored flag anchors and their entries, eleven header search paths, three source entries, the prefix header's macro body, eight renderer name overrides and two registry methods, one link-error table and `VibeStatusForPlayError` consolidated into one header, `AudioTrack.durationString`, two accessibility overrides and a duplicated constant, one catalog key, eighteen settings reads, and two imports. New here: `Common/StringRules.h`, `Common/WaveformTheme+Settings`, `WaveformUI/WaveformAccessibility.h`, one live-effect bit. New types: none. The two hand-kept test source lists are not consolidated yet. The tests must keep compiling production sources for verbose logging, the `-O2` render path and the decoy. They shrink as each piece's tests move.

**Not done here.** `Playlist/` and `NowPlaying/` stay. No shared subsystem references them. The `AudioTrack` split into a core track and a row model waits until someone needs the player without TagLib. Artwork keeps handing out `NSImage` and `UIImage`.

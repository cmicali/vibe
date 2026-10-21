# Future: vibe-libs, the shared toolbox

**Status: planned 2026-10-17, revised 2026-10-18 after two reviews, and revised 2026-10-20 after a third: the shell pieces join on a second track, as cuts 24 to 29, and the one prefix is `Vibe`. Merged on 2026-10-20: the pilot (#314 moved the realtime-effects brackets, #315 took the varispeed from the submodule), the log macros (#319), and cuts 1, 3, and 4 (#316 to #318). Cuts 6 to 11 and 24 to 29 merged on 2026-10-20. On 2026-10-21, #350 moved `core/Graphics` and #351 landed seam 13. Also on 2026-10-21, #353 to #359 landed seams 14 to 18, the queue half of 19, 22, and 23, and moved the mac controls and the settings window. #363 moved the rest of `core/Common`.**

Everything in Vibe that another app could use moves to [vibe-libs](https://github.com/cmicali/vibe-libs), a public toolbox of small libraries for macOS and iOS apps. Vibe and another app each take only the pieces they want. **vibe-libs' [docs/plan.md](https://github.com/cmicali/vibe-libs/blob/main/docs/plan.md) is the authority** for the pieces, their dependency map, the build shape, the order of the moves, the performance proof, and what the other app needs when. This doc covers only what changes in Vibe.

The other app is closed source and is never named in this repository or in `vibe-libs`. Call it "another app".

## How Vibe consumes vibe-libs

- **A git submodule at `vibe-libs/`**, pinned to a commit. `make project` initializes it (`scripts/build/vibe-libs-submodule.sh`). Every CI checkout sets `submodules: recursive`.
- **Templates, compiled in tree.** `project.yml` includes `vibe-libs/vibe-libs.yml` and lists each piece's template on both app targets, with `templateAttributes` naming the excluded platform. The pieces compile as Vibe's own sources, with the same flags.
- **Performance is measured for each move**, with the proof in vibe-libs' plan: fixed before and after commits, a no-change band per benchmark, and every outlier and rerun reported. Compiling in makes a change unlikely, not impossible.
- **A change across the repos lands in vibe-libs first**, then in Vibe's pin, then through Vibe's gates. The old pin is the rollback.

## What blocks the split, measured on `main`

Only five files in the moving code read `AppSettings`: one in folder art and four in the waveform views and theme. The real blockers:

1. **The prefix header.** `Vibe-Prefix.pch` gave every file the `Log*`, `VIBE_REALTIME_*` and signpost macros. The brackets moved in #314 and the log macros in #319. The signposts and the work tally moved with `core/Common`. They compile where `project.yml` defines `VIBE_SIGNPOSTS`, in Debug, since a vibe-libs header may not read `DEBUG`.
2. **Strings.** `AudioErrorRules.h` maps error codes to `STR_ERROR_*`. `AudioTrack` has two labels. Every renderer returns a localized style name. Metadata, Loading and Util have one site each.
3. **Debug imports in production code.** Seven were unguarded, for `AudioLoadTiming.h` and the work tally, and eight sit under `#if DEBUG`. The work tally moved to `core/Common`, so the one unguarded import left is the waveform loader's `AudioLoadTiming.h`. Its header carries `#if DEBUG`, so it needs a seam's shape before it moves with WaveformLoading.
4. **`Audio/` and `Loading/` imported each other.** One shared header of open rules, the loader's typed handle, and the read-ahead's test hooks made the cycle. Seams 14 and 15 below untangled it.
5. **One shell reach.** `FolderArtResolver` imports the mac's `FolderAccessManager`.
6. **Platform halves** are categories on `AudioPlayer` that the core calls under `TARGET_OS_OSX`. They cannot be a separate module.

## Where Vibe's code goes

| Group | Pieces | Mostly from |
| --- | --- | --- |
| `core/` | Common, Graphics | `Util/`, `NSURL+Hash`, and the prefix header's macros. `Common/Platform*` and `Common/Mac/Theme/Fonts` moved in #350. The rest of `core/Common` moved after it, with the work lanes from `Loading/Claim/` and the work tally from `Debug/Oracles/`. |
| `files/` | FileLoading, RemoteFiles, HTTP, ShareLinks, SandboxAccess, DiskCache | `Loading/`, `Mac/App/FolderAccessManager`, the cache helper |
| `audio/` | AudioTypes, DSP, Analysis, Decode, Meter, FX, OutputDevices, Player | `Audio/`, `Common/PlayableExtensions` |
| `media/` | Tags, Metadata, Playlists, FolderScan, PlayQueue | `Audio/Metadata/`, `iOS/Search/FileSearchIndex`, and the shared half of `Playlist/` except `AudioTrack`, which stays |
| `waveform/` | Waveform, WaveformStyles, WaveformLoading, WaveformView | `Packages/WaveformCore`, `Audio/Waveform/`, `WaveformUI/` |
| `ui/` | Controls, SettingsWindow, Shortcuts | `Controls/`, `Mac/Controls/`, `Mac/About/VibeLinkLabel`, the window, sidebar, pane base and form views of `Mac/Settings/`, the shortcut encoding of `Mac/Menu/ShortcutRules.h` and the Shortcuts pane |
| `system/` | NowPlaying, AppOpening, Updates | `NowPlaying/`, `Mac/App/OpenBurstCoalescer`, `OpenRequestCoordinator`, the Sparkle wiring |
| `dev/` | DebugChannel, iOSDriver | `Debug/Channel/`, `Tests/iOSDriver/` |
| `tools/strings` | the strings extraction and catalog checks | `scripts/strings/` |
| `third_party/` | each vendored library, Sparkle included | `ThirdParty/` |

**What stays in Vibe:** both shells, the playlist row (`AudioTrack`), the playlist table, the settings store and every pane's content, strings, themes and the Themes pane, the main menu and its command table, the About window, the link store, Dropbox, Convert to FLAC, the debug verbs and their command tables, and the widget.

**Moves with its users, no source change:** `NSString+CPPStrings`, `PlayableExtensions`, the debug seams, simulators, and `AudioLoadTiming`. `VibeWeakProxy`, `StallWatch` and `HelperMacros.h` moved with `core/Common`. `StallWatch` gained one import there, since it logs and no prefix header gives it the log macros in vibe-libs. A moved file that uses `clampRange` now imports `HelperMacros.h`. #350 had spelled it as `MIN(MAX())` in the two Graphics files that used it. The dark-mode helpers and the platform aliases moved with Graphics in #350. `NSView+DarkMode.h` first gained an AppKit import, because no prefix header supplies AppKit in vibe-libs. Convert is wholly `Vibe/Mac/Convert/` and stays. `AudioFileHandle`'s writing half stays in the engine. `VibeWidget/` is untouched.

**After the moves, `project.yml`** drops the `Vibe/Audio`, `Vibe/WaveformUI` and `Vibe/Controls` entries, the four vendored flag anchors and their 22 entries, and the eleven TagLib header search paths. `Vibe/Loading` keeps only `iOS/Dropbox` and the link store. `Vibe/ThirdParty` goes. `Vibe/Mac/Settings` keeps the panes and the window subclass. `Vibe/Mac/Controls` keeps the artwork view and the pitch controls.

## The cuts, as pull requests on `main`

Each is mergeable alone and leaves every check passing. The vibe-libs plan names the ones the first path needs. They are 1, 3, 4, 6 to 18, the queue half of 19, 22, and 23. The shell track needs 24 to 30.

| # | Cut | Today | The change | Status |
| --- | --- | --- | --- | --- |
| 1 | Seam parser | `Debug/Seams/AudioLoadingConfiguration+Debug.m` imports the channel's `DebugWireFormat.h` for one integer parser. | A local parser. A seam imports nothing from `Channel/` or `Verbs/`. | #316 |
| 2 | Playlist extensions | `Loading/Net/RemotePlaceholderStore.m` imports `PlaylistFile.h` for `isPlaylistExtension:`. | Move the three extension tests into `Common/PlayableExtensions`. | waits for RemoteFiles |
| 3 | Metadata cache root | `AudioTrackMetadataCache` cannot be given a root path. | `initWithRootPath:`, as `AudioWaveformCache` has. | #317 |
| 4 | Folder art providers | `FolderArtResolver -init` reads `useFolderArt` and calls `FolderAccessManager`. | The app installs both as providers, beside the `FolderWalk` handlers. | #318 |
| 6 | `Common/StringRules.h` | `VibeStatusForPlayError`, `LinkStore`'s 26 `STR_LINK_*`, eight renderer `+displayName` overrides and the registry's two name methods. | One header-only file in Vibe, the one place a library's code or identifier becomes a `STR_*`. Precedent `SettingsRules.h`. `styleIdentifiers` returns a stable order, and each shell sorts by name. | #334 |
| 7 | Formatters stays in Vibe | `AudioTrackMetadata.fileInfoLine`, both views' `accessibilityLabel`, `Formatters.percentString:`. | `fileInfoLineForMetadata:` moves to `Formatters`. Shells set the label where they build the view. A small `WaveformAccessibility.h` formats the percent. | #336 |
| 8 | Identifier macros | `SETTINGS_VALUE_WAVEFORM_*` in `AppSettings.h` are identifiers the registry and theme own. | Theme, band and palette identifiers go to `WaveformTheme.h`, and style identifiers to `WaveformRendererRegistry.h`. Names unchanged. | #338 |
| 9 | `WaveformTheme+Settings` | `themeForAppTheme:` and `themeForSettings:widget:` map Vibe's stores onto the theme. | A category in `Vibe/Common/WaveformTheme+Settings`, precedent `AppSettings+Themes`. `WaveformTheme` then imports only `PlatformColor.h`. | #340 |
| 10 | Mac `WaveformView` pushed | Nine `AppSettings` reads. | Pushed properties, a `dragSeeks` BOOL, and a `themeProvider` block. One shell method, `applyWaveformSettings`, pushes them. One new live-effect bit for the drag popup. | #342 |
| 11 | iOS scrubber pushed | Six reads. | `syncWaveformStyle` takes the resolved identifier. `centered` and `drawsPlayheadLine` are pushed. A `themeProvider` block replaces three `themeForSettings:` calls. | #344 |
| 12 | `CMMMacros.h` | The pch's macro body is what the libraries use. | Moves in parts: the realtime brackets first, then the log macros. The signposts and the work tally moved last, with `core/Common`, under the app's `VIBE_SIGNPOSTS` switch, since they are debug-only. The header is renamed `VibeMacros.h` on the pilot's branches before they merge, with `CMM_ROOT` and the template names (vibe-libs' plan, Decided). | brackets #314, logs #319 |
| 24 | Pane effects sink | `SettingsPaneViewController` holds `MainPlayerController` and calls `applySettingsLiveEffects:` once. | A block over an opaque integer, supplied by the controller. `VibeSettingsLiveEffect` stays here. | #335 |
| 25 | Settings window split | `SettingsWindowController` lists the nine panes, reads 34 strings, and names the Themes and Audio panes. | The generic window takes its panes as a list and its strings pushed in. A Vibe subclass supplies the panes and the Themes toolbar items. | #337 |
| 26 | Drawn slider formatter | `VibeSlider` calls `Formatters.percentString:` for its accessibility value. | One formatter block. | #339 |
| 27 | Fonts' slots | `Fonts` imports `AppTheme` for `VibeFontSlot` and `applyThemeFonts:`. | `Fonts` keeps a face-and-size table keyed by an integer slot. The enum, the five slots, and the theme push move beside `AppTheme`. | #341 |
| 28 | Shortcut encoding | `ShortcutRules.h` mixes the key-code-or-character encoding with Vibe's commands, their defaults, and the menu rules. | The encoding, the modifier mask, and the matching move. The command table stays. The Shortcuts pane takes rows of identifier, label, and default. | #343 |
| 29 | Color-pair row | The theme editor builds dark and light wells bound to an `AppTheme` base, seeds them, and copies and pastes them as hex. | The row, the seeding, and copy and paste move into `SettingsFormViews`, bound to a read block and a write block. The editor calls it. | #345 |
| 30 | Shortcuts pane pushed | `SettingsShortcutsViewController` reads `AppSettings`, `MainMenuBuilder`, the player's write path, and 15 strings. | The pane takes its rows, its strings pushed in, and blocks for the shortcut a command carries, its display, the override set, and the one assign. Vibe's settings window builds it. The assignment outcome moves to `ShortcutRules.h`. The encoding tests run over a table of their own, apart from the menu-rule tests. | |

Cut 5, which retired `AudioTrack`'s two labels, is not planned. `AudioTrack` stays in Vibe.

**The shell track** is cuts 24 to 30 and then four moves: the mac controls, `Fonts` with Graphics, the settings window, and the shortcuts. It runs beside Phase 2, since it touches none of the path's files. The mac controls moved in #354. The settings window moved in #356. Cut 30, the Shortcuts pane's rows, comes before the shortcuts move. After it, the pane and `ShortcutRules.h` name nothing of Vibe's. The theme record, its store, and the Themes pane stay here. The generic half of `DebugSettingsUI`, the walk from a row title to its controls, moves as the settings window's debug seam, and the theme verbs stay in the command tables. The order and the done-when are in vibe-libs' plan.

## The seams between pieces

The contracts are written in vibe-libs' plan. This is Vibe's side of each.

| # | Seam | Today | Vibe's change |
| --- | --- | --- | --- |
| 13 | The playable-item protocol | Nine shared areas import the playlist row. | `AudioTrack` adopts the protocol and moves to `Vibe/Playlist/`. The CUE window math goes to AudioTypes. (#351) |
| 14 | `AudioFileOpenRules.h` splits | Four areas imported its four parts together. | It split into four homes. The delivery states sit beside FileLoading's open token, in `AudioFileOpenDeliveryRules.h`. The path spelling is in `FilePaths`, now in `core/Common`. The mount rule and the span sit beside FileLoading's read-ahead. The tail window sits beside RemoteFiles' placeholder store, in `TailWindowMath.h`. Each importer takes only the part it uses. (#353) |
| 15 | The loader's handle | The loader named `AudioFileHandle`, in its opener's type and in the read-ahead's test hooks. | The handle is `ServedFileHandle`, which holds a stream. Interrupting stays the opener's `interrupted` block. Each `openURL:` passes its opener, so the loader never names the handle's class. The hooks are declared in `NetworkReadAhead+Debug.h`, and `AudioFileHandle (Debug)` forwards to them. (#353) |
| 16 | TagLib and artwork | The TagLib wrapper returned an artwork extractor and read remote ranges through the materializer. | Tags returns art bytes and takes a byte-range reader. (#358) |
| 17 | The waveform decode's analyzers | The loader built the tempo and key analyzers itself. | The app attaches them as observers. The archive moved to format 7. It files each result under its observer's identifier. (#355) |
| 18 | CUE and M3U | The readers returned `AudioTrack` rows. | They return records, and Vibe makes rows from them. (#359) |
| 19 | The play queue, then Now Playing | Both held `AudioTrack`. | The queue holds opaque entries. Vibe passes the URL and the source key as key blocks, and makes every replacement row with `replacementAtURL:`. Now Playing takes a snapshot when it moves. (queue half, #357) |
| 20 | The link store | It mixes share-link rules with track naming and strings. | The rules and the client move. The store stays. `LinkClient` stops importing `LinkStore`. |
| 21 | The shell pieces | The folder-grant panel, the pitch fader and the drawn controls read strings, fonts and `Formatters`. The Sparkle wiring reads the beta setting. | The app pushes each one in. |
| 22 | Metadata's holder protocol | The loader installed results through `AudioTrack (Internal)`. | `AudioTrack` adopts Metadata's protocol with the methods it has. (#358) |
| 23 | The walk's file handler | FolderWalk noted cover-art candidates itself, through `FolderArtRules.h`. | The app installs the handler at launch, beside FolderWalk's other handlers. It returns folder art's cover rank for each filename. (#359) |

Vibe's folder open becomes a caller of the catalog scan's walk, after FolderScan moves. Its rows and its behavior do not change.

## What changes in this repo's tooling

Done in #315: the submodule script, `submodules: recursive` on every CI checkout, `check-layout` assertion 7, and the submodule in `perf.py` and `scripts/bench/build-version.sh` worktrees. `perf.py`'s `tool_spec` copies `templates` and `templateAttributes`. Done in #350: `check-layout` assertion 4 counts a vibe-libs piece's `Mac/` and `iOS/` halves as that platform's tree. Done in #352, before the vendored libraries move: `scripts/build/analyze.sh` also drops findings under `/third_party/`.

Still to do, each with the move that needs it:

- `scripts/checks/check-layout.sh` substitutes `${excludedPlatform}` for assertions 1 and 2, and checks that no vibe-libs file imports a header whose only home is under `Vibe/` or `Tests/`.
- `VibeTests` and `VibeAudioTests` keep their hand lists until each piece's tests move. The production paths change prefix, and the vendored entries become template references.

## TRAPs

- **A template's settings replace a value the target takes from a settings group.** They join only the target's own `base`. So Vibe's app targets set their header search paths in `base`.
- **A checkout without the submodule compiles nothing from vibe-libs and fails late.** `make project`, `perf.py` and CI all initialize it. `check-layout` fails fast when it is missing.
- **YAML anchors do not cross `include:` files.** Every `*dr-libs-flags` reference becomes a template reference.
- **`scripts/build/analyze.sh` drops findings by two path substrings, `/ThirdParty/` and `/third_party/`.** The second is where vibe-libs' vendored code sits. A vendored library anywhere else fails the gate.

## Budget

Most of the shared code and its tests leave this repo. Deleted or unified in what remains: the vendored flag anchors and their entries, eleven header search paths, three source entries, the prefix header's macro body, eight renderer name overrides and two registry methods, one link-error table and `VibeStatusForPlayError` consolidated into one header, two accessibility overrides and a duplicated constant, eighteen settings reads, and two imports. New here: `Common/StringRules.h`, `Common/WaveformTheme+Settings`, `WaveformUI/WaveformAccessibility.h`, and one live-effect bit. The shell track deletes the form views, the pane base, the sidebar and the generic window, about 2,650 lines, five clean controls and the drawn controls, `Fonts`' table, the shortcut encoding, and the walker's generic half. New for it: the window subclass with the pane list, the font slot enum beside the theme, and the command table on its own. New types: the small ones the seams add, each argued in vibe-libs' plan. Each move reports what it removed from Vibe apart from what it added across both repos. The two hand-kept test source lists stay until each piece's tests move, since the tests compile production sources with their own flags.

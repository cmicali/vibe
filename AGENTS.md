# AGENTS.md

Guidance for any coding agent working in this repository.

Vibe is a native music player for macOS (`Vibe` target) and iOS (`VibeiOS` target), written in Objective-C and Objective-C++.

Playback uses CoreAudio, AudioToolbox and AVFoundation plus five vendored libraries, and no other third-party audio code. Each is a piece under vibe-libs' `third_party/`:

- **r8brain-free-src** resamples every file whose rate is not the output's.
- **dr_mp3** decodes MP3, MP2 and MP1.
- **dr_flac** decodes FLAC.
- **dr_wav** decodes WAV, W64, RF64 and AIFF.
- **libvorbis**, with libogg's page reader, decodes Ogg Vorbis.

The three dr_ libraries carry fixes of Vibe's own. Each piece's `AGENTS.md` lists them. `docs/audio-quality.md` has the measurements behind each choice.

The playable formats are listed once, in vibe-libs' `audio/AudioTypes` (`PlayableExtensions`). FLAC in Ogg is refused at the parser open, because CoreAudio truncates it (`AudioFileHandle.m`).

A CUE sheet, beside its files or embedded in a FLAC, plays as rows. Each row is a window of its file, and the player treats the window as the whole track (`Playlist/AGENTS.md`, `Audio/AGENTS.md`).

## Building

`Vibe.xcodeproj` is generated from `project.yml` by XcodeGen and is **not** checked in. Regenerate after cloning, after pulling and after every edit to `project.yml` with `make project`. Every `make` target that builds regenerates first. The Makefile comments each target; the traps are here.

**`vibe-libs/` is a git submodule**: the toolbox Vibe shares with another app (`docs/architecture.md`, vibe-libs). `make project` checks it out in a fresh clone or worktree. It also says when the checkout is not the commit this repo pins, and never moves it. A piece is changed in vibe-libs first, and then Vibe bumps the submodule. Read `vibe-libs/AGENTS.md` and the piece's own doc before changing a piece.

| Command | What it does |
| --- | --- |
| `make help` | Every target, with the first sentence of its comment. |
| `make build [CONFIG=Debug]` | macOS app; Release by default, into `build/DerivedData`. |
| `make build-ios [CONFIG=Debug]` | iOS app, generic simulator destination, unsigned, arm64 only. |
| `make install-ios [CONFIG=Debug]` | iOS app onto a paired device, signed. `DEVICE=<name or id>` when more than one is paired. |
| `make run` / `make install` | Launch; copy into `/Applications`. |
| `make compile-commands` | Writes `compile_commands.json`, which clangd, CLion and clang-tidy read. It covers both apps and `VibeTests`, Debug. Rerun it after adding a file. |
| `make clean` | Removes `build/` and the generated project. |
| `make reset-state [ARGS=-n]` | Wipes Vibe's persisted state (macOS container; `--both` adds the simulator app). Prompts; `-n` previews. |

**The debug command channel needs a Debug build.** It is compiled out of Release.

**There are three configurations.** Debug and Release are the direct download, which updates itself through Sparkle. AppStore is the Mac App Store archive, the one with no updater, built by `make build CONFIG=AppStore`. The iOS App Store path archives Release. `VIBE_DIRECT_DISTRIBUTION` is the one marker that tells them apart (`Vibe/Mac/App/AGENTS.md`, Updates).

Releases go through the **`vibe-release` skill**. The Developer ID path (`make release`) and the App Store path (`make appstore-build`, `make appstore-upload-signed-build`) are not interchangeable. Do not improvise from the scripts.

## Checks

All of these run in CI (`.github/workflows/build.yml`). `make test-ios` runs only nightly and on manual runs. Run it yourself when a change touches the iOS shell.

| Command | Gate |
| --- | --- |
| `make test` | Host-less unit and orchestration tests (`Tests/`, always Debug) plus the cloud-runner oracle tests. **Read `Tests/AGENTS.md` before adding to it.** |
| `make test-audio` | The real player and FX pipeline driven by the debug render pump, full PCM comparisons and signal-quality checks; no app or audio device. See `Tests/AGENTS.md`. |
| `make test-ios` | The iOS shell's views and controllers (`Tests/iOSSim/`), hosted in the Debug app on a simulator. `IOS_TEST_DEVICE` names the simulator. See `Tests/AGENTS.md`. |
| `make test-summary` | Markdown pass/fail table from the last `make test`, with the skip gate. `test-audio-summary` and `test-ios-summary` read the other two suites. |
| `make analyze CONFIG=Release` | clang static analyzer over **both** app targets. Fails on any finding outside `ThirdParty/` and vibe-libs' `third_party/`. Findings depend on the configuration, and CI checks Release. |
| `make check-layout` | The layout rule below. |
| `make check-vocabulary` | The mechanical vocabulary rules below, and no doc line over 1500 characters. |
| `make check-strings` | Fails when `Resources/Localizable.xcstrings` is stale against the source. |
| `make check-translations` | Fails when any key in any catalog is missing a language. Both release paths run it; CI only reports. |
| `make appstore-validate-copy` | App Store copy completeness and caption fit. |

Anything that must be verified against the *running* app belongs in the debug command channel, not in a unit test.

## Complexity budget

Every check above passes as happily on a 400-line addition as on a 40-line one, so none of them constrains complexity. This section does, and it is as much a part of done as they are.

**The budget for a feature is zero new concepts.** Fit new behavior into whatever already owns the concern. The subsystem map says which. A new class, protocol, `*Rules.h` or directory for new behavior is a request made *before* the code is written, argued on the feature's own terms. "It needs its own state machine" is the claim under question, not a reason for one.

**Moving existing code to the directory that owns it needs no argument.** A split should follow an existing responsibility. Explain any new type, ownership boundary, lifetime, or shared interface it introduces. Preserving behavior does not make added structure free.

**Say what the change removes.** Every change reports its net line count, new files, new types, and either what it deleted or unified or a plain statement that it consolidated nothing and why. A "nothing, because …" that reads badly is itself the finding: a feature that touches a subsystem and simplifies nothing in it is usually in the wrong place. Shorter files are not by themselves evidence of simpler code.

**Deleting and rewriting are expected, not risks to be managed.** `make test`, the stress suites and git make them recoverable. Never keep a mechanism because it exists, was expensive to write, or is only *probably* dead. Find out what reaches it. If nothing does, remove it in the same change. Two mechanisms splitting one job is worse than either alone.

**Prefer the boring shape.** A branch in an existing method beats a strategy object. A field beats a state machine. A direct call beats a notification. A parameter beats a coordinator. Reach for machinery only once the simple shape has been written and fails, never in anticipation.

**The consolidating pass is part of the feature.** Once it works, re-read the whole file it landed in and fold the new code into what was already there. `/simplify` in a *fresh* session does this better than the session that wrote the code.

## Debugging and verification

The **`vibe-debug` skill** launches, drives, inspects and screenshots either app. It is the reference for the debug command channel (`Vibe --debug-cmd <command>`, debug builds only, `Vibe/Debug/`), the iOS simulator loop, log streaming and the launch-time build-provenance block. The command list lives in the skill and in the channel's own unknown-command reply, deliberately not here.

The **`vibe-stress` skill** (`make stress`, `make torture`) is soak runs, leak and resource-growth hunting, TSan race hunting, fuzzing the file-loading path, and shrinking a failing run to a repro. Read `vibe-debug` first.

The **`vibe-perf` skill** is performance. VibeBenchComponents (`Tests/BenchComponents/`) drives the production code in-process and counts retired instructions, so two refs compare fairly on a busy machine (`perf.py compare main`). Measure a change that could move cost before and after (`make bench-components`). `docs/performance.md` charts every release, and `make bench-releases` regenerates it.

The **`vibe-waveform` skill** draws a real track's waveform as the iOS scrubber draws it, without the app, at any time, zoom and ref. It also prints what each pixel is drawn from. Use it to reproduce a waveform screenshot and to compare main with a change.

The **`vibe-audio-quality` skill** is audio quality and conformance. It runs public conformance and torture corpora through the decoders. They are downloaded on demand and never committed. It also keeps `docs/audio-quality.md`'s charts and corpus results current. Run it after changing a decoder, a parser or the file-open path.

Test audio: `Assets/test_audio_files/` (gitignored). If missing, generate it with `scripts/test/generate-test-audio.sh`. Never synthesize your own.

**Before calling a feature unbuilt, look past `main`'s working tree.** A pull request is sometimes based on another feature branch, so merged work can sit off `main` for a while. `git log --all --oneline -S <symbol>` settles it.

## Layout: the directory is the platform boundary

Every directory directly under `Vibe/` except `Mac/`, `iOS/` and `ThirdParty/` is a shared subsystem compiled into both targets. `Packages/WaveformCore/` is outside `Vibe/` because it is meant for other apps too. It compiles into both targets and names no platform. `vibe-libs/`, the toolbox submodule, is outside `Vibe/` for the same reason. Its templates compile its pieces into both targets. Within a subsystem, `Mac/` and `iOS/` are the only platform markers. `project.yml` lists one recursive source entry per shared subsystem and per macOS app-shell piece.

**A new file in a shared directory joins the iOS target automatically.** It must be AppKit-free or `TARGET_OS_OSX`-guarded. A shared source may not `#import`, unguarded, a header that only one platform's tree has. Xcode's project-wide headermap resolves it by basename whatever the target, so it compiles and then fails at runtime or link.

`make check-layout` enforces the rule, and its header is the authority. One of its assertions fails on any `CLAUDE.md` or `CLAUDE.local.md` in or above the tree, because one makes Claude Code skip every `AGENTS.md`. CI's iOS builds catch an AppKit leak.

## Subsystem map

`docs/architecture.md` is the overview for human readers: the tree, each subsystem, the path from open to sound, and where to look for what. Nested `AGENTS.md` files hold the detail. **Read the relevant one before changing anything it covers.** Docs follow the platform boundary. A shared subsystem's doc covers what both platforms have, and platform-specific detail lives in a doc under its `Mac/` or `iOS/` directory. `.md` files are excluded from every source entry, so a doc can go anywhere without touching the build.

- **`Vibe/Common/`** — what everything else is written in terms of: `AppSettings` (its macOS half is `Mac/`; `Mac/Theme/` is the theme store, the `AppTheme` record, its one sanitization gate, the archive form, the dice and the font slots), `VibeStrings.h`, the prefix header and `DocumentTypes`. No feature lives here.
- **`vibe-libs/`** — the shared toolbox, a git submodule. Vibe uses `audio/AudioTypes` for the playable-item protocol, the CUE window math, the musical key, the format names, and the playable extensions, `audio/DSP` for the varispeed, `files/FileLoading` for the file-open path and the fake cloud, `files/DiskCache` for the bounded disk cache, `core/Graphics` for the image, color, and font helpers, `ui/Controls` for the mac's drawn controls, `ui/SettingsWindow` for the mac's generic settings window and form views, `ui/Shortcuts` for the shortcut encoding, the keyboard layout, and the Keyboard Shortcuts pane, and `core/Common` for the macros, the paths, the disk key, the work lanes, the stall sampler, build provenance, and the other featureless helpers. Only the mac app lists `ui/Controls`, `ui/SettingsWindow`, and `ui/Shortcuts`, which are macOS only. vibe-libs' own `AGENTS.md` and each piece's doc govern it.
- **`Packages/WaveformCore/`** — the waveform engine, kept free of app types for reuse in other apps: the summary of an audio stream, its exact reads, the zoom steps, the coverage raster and deep zoom's detail. It is a Swift package with its own tests. Both apps and the tests compile its sources directly. In Vibe its summary is `AudioWaveform`.
- **`Vibe/Audio/`** — playback engine, FX, waveform data, BPM/key analysis. `FX/` (the DJ master-bus segment, optional per player via `enableFX:`, and the pitch fader's stage), `Metadata/` (tags, cache, scan; `Artwork/` is embedded art and the shared thumbnails, and `Artwork/FolderArt/` the sidecar-cover fallback), `Waveform/` (data), `Analysis/` (tempo and key), `Levels/` (live FFT levels from the render's final samples), `Mac/Devices/` (CoreAudio HAL output devices), `iOS/` (audio session and output recovery) each have a doc.
- **`Vibe/Loading/`** — the app's own transfers. The file-open path itself is vibe-libs' `files/FileLoading`: the placeholder checks, the materialization claim, admission, the handle-run ceiling, `CloudTransferRegistry`, the download progress monitor, `CloudFileMaterializer`, the abortable download, and `NetworkReadAhead`, the read-ahead of a file on a network mount. `Net/` is the app's own HTTP side: the HTTP transfer, the placeholder store, and Open URL's links. `iOS/Dropbox/` is the Dropbox account and its local mirror, iOS only. Its client and mirror subclass the transfer and the store.
- **`Vibe/NowPlaying/`** — the bridge to the system's Now Playing info and remote commands. Both shells drive it.
- **`Vibe/Controls/`** — controls both platforms draw the *same* way: the equalizer bars that mark the playing row, and the loading indicator.
- **`Vibe/Playlist/`** — the row (`AudioTrack`), the model, the folder walk, and the CUE and M3U readers and the M3U writer (`PlaylistFile`). `Mac/` is the table and the session save and restore (`PlaylistFile+Session`).
- **`Vibe/WaveformUI/`** — waveform *rendering*: `WaveformTheme` and the iOS zoom floor, shared; `Renderers/` the strategies, the morph engine and the level mapping; `Mac/` the `NSView`, `iOS/` the scrubber. Named apart from `Audio/Waveform/` deliberately — one makes the data, the other draws it.
- **`Vibe/Util/`** — Vibe's own featureless helpers, with `Mac/` and `iOS/` halves. Those another app could use are in vibe-libs' `core/Common`. **`Vibe/Debug/`** — the debug channel, with `Mac/` and `iOS/` command tables.
- **`Vibe/Mac/`** — the macOS app shell, one directory per piece: `App/` (application object, open funnel, sandbox grants, stats, the debug info report), `MainWindow/` (`MainPlayerController`; layout and chrome are its `LAYOUT.md`; `Transport/` carries its own doc), `Menu/` (the menu bar and Vibe's command table, over vibe-libs' `ui/Shortcuts`), `Controls/` (the artwork view and the pitch controls; the other mac controls are vibe-libs' `ui/Controls`), `Settings/` (Vibe's panes and window subclass, over vibe-libs' `ui/SettingsWindow`; the Keyboard Shortcuts pane is `ui/Shortcuts`'; `Themes/` is the theme list and editor), `About/`, `Convert/` (the FLAC converter and its file round trip, with a doc).
- **`Vibe/iOS/`** — the iPhone/iPad app shell: `PlaybackController` (the model), the tab shell, the Playlist tab and the mini player; `Files/` is the Files tab's browser and Recents, `Player/` the now-playing card, `Search/` Favorites and search, `Settings/` the settings screens, `Widget/` the widget's app side, each with a doc. The top-level `VibeWidget/` is the widget extension, with its own doc. The iOS halves of shared subsystems live under those subsystems, not here.
- **`Vibe/ThirdParty/`** — the prebuilt Sparkle framework, the direct download's updater. It stays here until the Updates piece moves.
- **`vibe-libs/third_party/`** — the vendored TagLib subset, PINCache and PINOperation, r8brain-free-src, dr_mp3, dr_flac, dr_wav, libvorbis, and libogg. Each is a piece with its own template, flags, license, and `AGENTS.md`. The dr_ libraries, PINCache, and PINOperation carry changes of Vibe's own. TagLib carries packaging edits. Each piece's doc lists them. Both app targets list the templates.

## Cross-directory guarantees

A **guarantee** is a condition the code must keep true, written once so a new call site can be checked against it. Each side is documented in its own directory. The coupling lives here.

**A guarantee is a cost, not an achievement.** Every bullet is a rule each future change is checked against. Before adding one, try to remove one. The change that needs a new rule can often retire an old one. Two bullets that state one rule are one bullet. A rule with a single call site belongs in that directory's own doc. The best version of a change deletes a guarantee.

- **Tags beat analysis.** A tagged tempo (`AudioTrackMetadata.bpm`) beats the analyzed one (`AudioTrack.detectedBPM`). A tagged key beats `detectedKey` the same way. `AudioTrack.bpm` and `.key` are the only homes of both rules. A cue row skips its file's tags, which describe the whole image, so its tempo and key come from analysis of its window. Key analysis is macOS-only, so on iOS the key comes only from tags.
- **Embedded art beats folder art.** Decodable embedded artwork always wins. A cover beside it (`FolderArtResolver`) can stand in when embedded art is absent or undecodable. A failed extraction stays unknown and does not enable the fallback. Folder art is resolved lazily per directory, off the metadata scan's path, and never persisted. The metadata cache is keyed by the audio file's size and mtime, which a sidecar image cannot move. A folder without an *active* grant is skipped, because background work must never raise a permission panel.
- **The equalizer bars show the final output, and do no work while unseen.** One demand-driven meter reads the output samples inside the render. It is the last stage of `VibeMasterBusRender` before the volume stage, which also applies the debug `--silent` zero. It runs after the FX returns, so it reads what reaches the device at full volume. Each shell hands its rows an `EqualizerLevelSource`. A nil source is inactive, never a synthetic animation. A view polls only while there is output audio and the view is materially visible, attached, sourced and nonempty. Each running poller declares one balanced `equalizerLevelsWanted:` consumer. At zero consumers the player removes its meter, except for the beta signal capture after each start. The player's drain timer runs only while the output runs voices. **Output audio is modeled, never guessed.** Pending play intent is not output. A tracked outgoing fade is. An FX tail after every source stopped is not approximated with a timer. Material visibility is each shell's own fold (`Playlist/Mac/AGENTS.md`, `iOS/AGENTS.md`). The renderer contract is in `Controls/AGENTS.md`, the producer contract in `Audio/Levels/AGENTS.md`.
- **Four features are macOS-only, each switched off in one place rather than compiled out.** Folder art: `AudioTrackArtwork` leaves its `folderArt` handle nil on iOS. Key analysis: the iOS analysis provider (`PlayerViewController`) never lists the key's observer. The pitch fader's varispeed: `ensureSourceSegmentOnQueueRebuilt:` hosts one only on macOS. The volume stage: only the mac sets `AudioPlayer.volume` below 1, because iOS uses the system volume. Under bit-perfect output a volume below 1 is reported, not refused. Their settings (`useFolderArt`, `analyzeKey`, the pitch fader's, `volumeControl`) are declared only in `AppSettings+Mac.h`. **The DJ FX and BPM detection run on both platforms**, from the shared `audioFXEnabled` and `analyzeBPM`. Both feed `AudioFX.delayTapBPM` from `AudioTrack.bpm`.
- **The 128px thumbnail is for list rows only.** Both platforms decode row thumbnails through `AudioTrackArtwork`'s shared bounded cache. The mac header and the iOS now-playing page draw the display-art rendition archived beside the metadata entry (640 px mac, 1024 px iOS; `Audio/Metadata/AGENTS.md`). A usable rendition avoids rereading the audio file. A missing or undecodable rendition falls back to source extraction.
- **A track is named on screen in one place.** `AudioTrack.displayTitle` and `.displayArtist` choose between tagged title and artist and the single line derived from the filename. A nil `displayArtist` means no second line. **The single line is still the title, so it takes the title's colour on both platforms.**
- **The open the user is waiting on outranks every background read that would download a file.** `AudioFileMaterializationCoordinator` derives "a foreground transfer is active" from its own claim table. A playback or prefetch waiter counts, and so does a readable stream still downloading under a handle it served. When the hold rises, the coordinator yields metadata-only dataless claims and cancels their downloads. It rechecks the hold before entering a provider operation. **A file already local is exempt.** Each shell also defers the metadata sweep until the picked track's open settles (`scheduleDeferredMetadataLoad`). The coordinator's half is in vibe-libs' `files/FileLoading/AGENTS.md`. The sweep's retries are in `Audio/Metadata/AGENTS.md`.
- **The handle-open ceiling is derived from one player with two open sources, and from every wait for bytes being interruptible.** There is one production `AudioPlayer` per process, with a playback slot and a prefetch slot. The gapless successor is the parked prefetch handle, never a third open. The coordinator permits six purpose-blind handle runs. The four beyond two are for opens stranded in the OS. Prefetch may use all six, and a later playback key is then refused rather than starting a seventh worker. **A wait for a file's bytes happens only on decode, loader and open workers, never on the render thread or main, and every app-owned byte wait can be interrupted** (`AudioFileHandle`'s `interruptReads` and `interrupted:`). Adding a player or an open source, making a source multi-flight, or adding a wait that cannot be interrupted means re-deriving the ceiling and its tests. The derivation is in vibe-libs' `files/FileLoading/AGENTS.md`, and the ceiling's tests are that piece's.
- **A folder opens in one order, chosen by the shell and applied by the walk.** Each shell reads `AppSettings.folderOpenSort` on main with the rest of its open snapshot (`AppDelegate.openURLsWithRestoredAccess:token:` on the mac, `FolderSession` on iOS) and passes it to the walk. The walk reads no setting (`Playlist/AGENTS.md`). The order applies only to what the walk expanded. The user's top-level URLs and a playlist file's order are kept. A setting change does not re-sort an open playlist.
- **Async deliveries race track changes.** Waveform, BPM, key and metadata deliveries can arrive after the track has changed. A receiver matches the delivered track before applying it. A waveform matches the current track. A tempo or key matches each row it stamps (`Playlist.stampTracksSounding:usingBlock:`). Anything computed per window matches by the item's `sourceKey` (`VibePlayableItem`), since every cue row of an image shares its URL. Metadata belongs to the file and matches by URL.
- **A play's settlement is matched by submission identity, not by track.** `didStartPlaying:` and the play-path errors are dropped when a newer play has been submitted (`AudioPlayer.submittedPlayIsCurrent:`). Replaying the same row produces the same `AudioTrack` and URL, so a content-based guard would accept the previous play's settlement.
- **The waveform theme always beats the style's built-in palette, and is resolved in one place.** The style is the geometry and the theme is the colors. 3-Band's three band colors stand in for the waveform color (`bandColors`). Spectrum's palette gives its three colors (`spectrumColors`). `WaveformTheme` (`Vibe/WaveformUI/`) is the only home of the rules from identifier to colors. Each view resolves the appearance and the settled artwork color through the `themeProvider` block its shell installs, and re-resolves on an appearance flip. **The `album_art` color rides the artwork install path on both platforms**, which closes the delivery race. `VibeDominantColorOfImage` is the one extraction. **The color is per view, not per app**, because the iOS pager shows a different track on every page. No art, or art too gray, resolves to Mono's answer.
- **Every themed appearance choice reads `AppSettings.currentTheme`, and every edit funnels through `currentThemeDidChange`.** A theme holds only how the window looks. What the window shows (readouts, playlist columns, the Dock tile) is `AppSettings`, so a theme switch never hides anything. The theme store never applies effects. The writer requests the mapped `VibeSettingsLiveEffect`. A `single`-mode theme pins the window dark (`requiredWindowAppearance`) and outranks `AppSettings.windowAppearanceStyle`. The record, its one sanitization gate and the built-ins are in `Common/Mac/Theme/AGENTS.md`. macOS-only.
- **A `VibeMusicalKey` of 0 is C major, not "none".** Every fresh holder must be set to `VibeMusicalKeyNone` (-1) explicitly. A zero-filled ivar or a message to nil reads as a tagged C major.
- **What follows a track end is `Playlist.trackEndSuccessor`, and every prefetch parks it.** It is the next row, the next entry of the shuffled order, row 0 or a fresh order under Repeat All, the track itself under Repeat One, or nil to park. No shell computes a successor from a row index. `AppSettings.pauseAtTrackEnd` outranks the modes. Each shell pushes it into `Playlist.pauseAtTrackEnd` with repeat and shuffle, and `trackEndSuccessor` is then nil. `advanceAtTrackEnd` and the gapless splice's `advanceFromTrack:toTrack:` both follow it. A writer of Pause, repeat or shuffle must push and re-park (`VibeSettingsLiveEffectEndOfTrack` on the mac, `PlaybackController.applyTrackTransitionSettings` on iOS). One that skips it advances through a splice armed for the old successor.
- **A structural playlist edit is a model edit plus a transport decision, and only the shell makes the second.** `Playlist.removeTracksAtIndexes:`, `insertTracks:atIndexes:` and `moveTracksAtIndexes:toIndexes:` are batch-shaped and touch no audio. Every removal funnels its rows through `MainPlayerController.removePlaylistRows:`. It owns the unload, the re-prefetch through `prefetchSuccessor` and the replacement play. Each caller registers its own undo. A move is transport-safe because the current object survives. Its whole follow-up is `playlistOrderDidChangeHandler`. **A structural edit never touches a file.** One structural edit sends one observer event. The mac applies it with precise row operations, never `reloadData`. iOS implements the three observer methods as no-ops. Landing rules and undo are in `Mac/MainWindow/AGENTS.md`, cursor and index rules in `Playlist/AGENTS.md`, drag and slot arithmetic in `Playlist/Mac/AGENTS.md`.
- **`AudioPlayer.stop` fires no transport or track-end callback.** It must never drive auto-advance, and the caller owns the UI reset. Track end and skip past the end both funnel through `didFinishPlaying:`.
- **A row shows the loading bar only while a transfer is running for its file, and everything that shows loading reads `CloudTransferRegistry`.** `AudioFileMaterializationCoordinator` publishes to it only when it classifies a file as dataless. A local file and a claim queued behind lane capacity publish nothing, so dropping a large cloud folder marks only the files on the wire. The registry runs the one monitor per transfer. The rows, each shell's loading fill and the player's open deadline observe it, and nothing else watches a file. In the gutter, loading outranks the playing marker. The registry is in vibe-libs' `files/FileLoading/AGENTS.md`, the row wiring in `Playlist/Mac/AGENTS.md` and `iOS/AGENTS.md`, the control in `Controls/AGENTS.md`.

## Vocabulary

One word per pattern. A new synonym is a bug.

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
| `output unit` | the hosted `AudioOutputUnit` that pulls the render: HALOutput on macOS, RemoteIO on iOS (Apple's `kAudioUnitType_Output`) | the device, the route, or the debug pump (`VibeManualRenderPump`, Apple's "manual rendering") |
| `embedded` | art carried in the audio file's own tag | the folder's cover |
| `cover` | the sidecar image beside the audio file | embedded art |

**Prefixes and suffixes.** `Vibe` prefixes C-linkage symbols. It also prefixes the few classes that would otherwise read as generic or collide with a system name (`VibeManualRenderPump`, `VibeFakeCloud`, `VibeWeakProxy`). An ordinary feature class has no prefix. Header-only files of `static inline` logic are the testable seams. They are `*Rules.h` when they return a decision and `*Math.h` when they return a number in the problem's units.

Behavior added to a foreign class is a category (`NSURL+Hash`), never a free function taking that class first. The two exceptions are in vibe-libs' `core/Graphics`, because the class differs per target: `PlatformImage.h`'s bounded decode and `PlatformColor.h`'s hex and blend functions.

**`Coordinator` is deliberately generic** and names three contracts: request identity (`PlaybackRequestCoordinator`), single-flight ownership (`MetadataParseCoordinator`, `AudioFileMaterializationCoordinator`), and ordered, target-matched delivery (`OpenRequestCoordinator`, `PageWaveformCoordinator`). A new one must say which it is.

`make check-vocabulary` enforces the mechanical half of these rules and is the authority on what is checkable. One rule it enforces is stated only here: **no `#if DEBUG` in a shipping header.** Debug surface is declared in a `+Debug` category header under `Vibe/Debug/`, with no allowlist. A vibe-libs piece keeps each seam beside the class it opens. Its header carries no `#if DEBUG` at all, and its `.m` wraps its body in one (vibe-libs' `files/FileLoading/AGENTS.md`). Its methods live beside it in `<Class>+Debug.m` when the class's header or `*Internal.h` is enough. Otherwise they stay in the class's own file under `#if DEBUG` (`Debug/AGENTS.md`). A debug-only property ships as a pointer. Debug-only *state* belongs to a debug-only object the shipping class holds (`VibeManualRenderPump`). A debug-only field a seam reads is declared unconditionally in the class's private header, marked as debug-only.

## Logging

`LogError`, `LogWarn`, `LogInfo` and `LogDebug` wrap `os_log`. They are vibe-libs' `core/Common/VibeMacros.h`, which `Vibe-Prefix.pch` imports. So are the signposts and the work tally. They compile only where `project.yml` defines `VIBE_SIGNPOSTS`, which is the Debug configuration. Their subsystem is the main bundle's identifier, `com.commonwealthrecordings.Vibe` for both apps. `OS_ACTIVITY_DT_MODE=1` in the environment copies them to stderr, which is how a debug build on an iPhone gets its log back (the `vibe-debug` skill).

**`VIBE_BETA_DEBUG` (`project.yml`) is the beta switch.** It sets `VIBE_VERBOSE_LOGGING` and the mac's Beta updates default, so a release flips one line. A Debug build is always verbose, whatever the switch says. At `VIBE_VERBOSE_LOGGING=1`, info, debug and warn are written at Default level, and Settings > Advanced > Save Debug Info retrieves them. At 0, info and debug must be streamed live. Keep each beta's dSYMs to symbolicate stall stacks.

Playback diagnostics are in `Audio/AGENTS.md`, hardware observation in `Audio/Mac/Devices/AGENTS.md`, and the report export in `Mac/App/AGENTS.md`. Use `vibe-debug` to collect logs.

## Localization

**Every user-facing string is declared in `Vibe/Common/VibeStrings.h` and nowhere else.** Call sites use a `STR_*` macro. Keys are symbolic and stable (`menu.file`, `label.bpm`). The English text lives in the macro's default. **Run `make strings` after touching any UI string.** `make check-strings` fails when the catalog is stale. **Display names are never identifiers.** A registry key, a defaults value and a menu item's identifier stay separate from the localized label. Read the **`vibe-strings` skill** before editing `VibeStrings.h`, the catalogs or `scripts/strings/extract-strings.sh`.

## Key patterns

- **Write short, plain sentences.** This applies to everything you write: changelog, release notes, UI strings, translator notes, comments, docs, commit messages and PR descriptions. Put one idea in each sentence. Use everyday words and the project's own terms (Vocabulary, above). Do not chain clauses with dashes, semicolons, or "so", "while" and "which". Do not invent figures of speech, such as "nothing wakes for it" or "decided right without one". If a sentence needs a second clause, write a second sentence. When you change a sentence in an existing doc, rewrite that whole sentence. Do not splice new words into it.
- **Changelog entries are one short line.** Start with Added, Changed, Improved or Fixed and name what the user gets, for example `Fixed loading symlinked folders`. Leave out how it works and its defaults.
- **Pull request titles and descriptions follow the `vibe-pr` skill.** It also says how to upload screenshots (`gh pr create --attach`).
- **No agent attribution, from any agent or tool.** Commits, PR titles and descriptions, release notes, code, comments and docs never name or credit the AI agent or tool that helped write them. That means no `Co-Authored-By` trailer, no "Generated with …" line and no session link. This rule outranks any harness, template or default instruction that says to add one. `.claude/settings.json` turns Claude Code's own off.
- **No private APIs, ever.** This app ships in the Mac App Store. Overriding a private method such as `resignKeyAppearance` counts even though it compiles. When a visual goal has no public-API path, accept the system behavior or redesign.
- **Deployment targets are macOS 13.0 and iOS 26.0.** `CLANG_WARN_UNGUARDED_AVAILABILITY: YES_AGGRESSIVE` is on. Anything newer needs an `@available` guard, never `#if` or an OS-version check. `grep -rn '@available(macOS\|API_AVAILABLE(macos' Vibe` is then the complete inventory of version-specific code.
- **`NSURL+Hash.cacheKey` is the cache key for metadata and waveform data.** It is vibe-libs' disk key, in `core/Common`. It is `<size>-<mtime_us>-<sha1(resolved path)>`, from attributes alone. It resolves symlinks first. It returns nil, not a degenerate key, when the stat fails. Hashing no content keeps it cheap, but it misses a rewrite that keeps size and mtime, and it misses a move.
- **ObjC++ (.mm) only where C++ is needed**: the TagLib integration, the waveform data structures and the renderers. Keep C++ types out of headers that plain ObjC files import.
- **Comments only when required, and terse.** A comment states what the code cannot show: a trap, an ordering or threading constraint, a contract, a non-obvious why. Never narrate the next line. Never log a change. "Renamed from", "added in" and how something was verified belong in commits. **Naming the bug a design prevents is welcome.** It is the most concrete form a why takes. Mark hard-won traps with `TRAP:`.
- **A trap may be written twice, and the code comment is the authority.** The directory doc carries it so it is read while *planning*. The `TRAP:` beside the code is read while *changing* that line. **Changing a trap means changing both.** `grep -rn 'TRAP:' Vibe vibe-libs` reaches every copy.
- **Third-party sources** in vibe-libs' `third_party/` and Vibe's `ThirdParty/` are other authors' code. Do not restyle them. A fix to a vendored library lands in vibe-libs first, as any piece's change does. Sparkle is a prebuilt framework. It stays in `Vibe/ThirdParty/`.
- **No backwards compatibility for anything unreleased.** A settings key, stored identifier, or format introduced since the last release is renamed or deleted outright, with no migration and no legacy alias. For a shipped one, ask before writing a migration. `Common/AGENTS.md`'s stored-key trap is about shipped keys.
- **The checkout is shared with other sessions.** `git status` and `git diff` mix authors. The branch can change underneath a session. `build/` can vanish to another session's `make clean`. So:
  - Report a change from an explicit list of the files it touched, never a bare `git diff --stat`.
  - Never revert or tidy modifications you did not make.
  - Run `git branch --show-current` immediately before every commit.
  - Stage by path. Never `git commit -a`, which can sweep another session's edit into your commit.
  - Build a PR branch in its own worktree (`git worktree add .claude/worktrees/<name> -b <branch> origin/main`, gitignored), so the main checkout stays on `main`. `make project` then checks out the vibe-libs submodule in it.
  - For a long loop over a built test bundle, copy it out of `build/` first.
- **Never post to a GitHub issue or PR thread without asking first, every time.** The threads are public, and the maintainer is the voice in them. Draft the comment in chat and wait. An approval covers that one post. Filing a new issue is confirmed first too. Reading and analysis need no approval.
- **Intel Macs get correctness and nothing more.** CI compiles the x86_64 slice in its AppStore build. It runs no x86 tests. When an x86_64 or Rosetta difference turns up, make the tests and docs right with arch-guarded assertions and a scoped sentence. Apple's MP3 decoder is one example: 16-bit on arm64, float32 on x86_64 (`docs/audio-quality.md`). Add no Intel-only features, benchmarks, chart redraws or CI legs unless asked.

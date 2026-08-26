# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

Vibe is a native music player for macOS (`Vibe` target) and iOS (`VibeiOS` target), written in Objective-C and Objective-C++. Playback is Apple frameworks only — `AVAudioEngine` and CoreAudio, no third-party audio library. Formats: MP3, MP2, AAC, AIFF/AIF, WAV/WAVE/BWF, FLAC, M4A, MP4 (`Common/PlayableExtensions`, the one home of the set). OGG is not supported.

## Building

`Vibe.xcodeproj` is generated from `project.yml` by XcodeGen and is **not** checked in. Regenerate after cloning, after pulling and after every edit to `project.yml`:

```bash
xcodegen generate        # or: make project
```

| Command | What it does |
| --- | --- |
| `make build [CONFIG=Debug]` | macOS app; Release by default. Regenerates the project, writes to `build/DerivedData`. |
| `make build-ios [CONFIG=Debug]` | iOS app, generic simulator destination, unsigned. Exactly what CI's `build-ios` job runs. |
| `make install-ios [CONFIG=Debug]` | iOS app for a paired physical device — signed, then installed over the CoreDevice tunnel. Needs a development certificate; `DEVICE=<name or identifier>` when more than one device is paired. |
| `make run` / `make install` | Launch; copy into `/Applications`. |
| `make clean` | Removes `build/` and the generated project. |
| `make reset-state [ARGS=-n]` | Wipes Vibe's persisted state — the macOS sandbox container, and with `ARGS=--both` the simulator app. Prompts first; `-n` previews. |

Debug builds are what the debug command channel needs — it compiles out of Release entirely.

Releases go through the **`vibe-release` skill** (`.claude/skills/vibe-release/`): the Developer ID path (`make release`), the App Store path (`make appstore-build`, `make appstore-upload-signed-build`), the shared App Store Connect API key, and the signing traps each script preflights. The two paths are not interchangeable — do not improvise from the scripts.

There is no package manager. TagLib and PINCache/PINOperation are vendored under `Vibe/ThirdParty/` and compile into both app targets.

## Checks

Everything below runs in CI (`.github/workflows/build.yml`) and can be run locally.

| Command | Gate |
| --- | --- |
| `make test` | Host-less unit/orchestration tests (`Tests/`, `VibeTests` target, always Debug) plus the cloud-runner oracle tests; provider, TagLib and other nondeterministic external boundaries stay injected. **Read `Tests/CLAUDE.md` before adding to it.** |
| `make test-summary` | Markdown pass/fail table from the last `make test`. |
| `make analyze CONFIG=Release` | clang static analyzer over **both** app targets; fails on any finding outside `ThirdParty/`. Findings are config-dependent — keep Release clean, which is what CI checks. |
| `make check-layout` | The layout rule below. |
| `make check-vocabulary` | The mechanical vocabulary rules below. |
| `make check-strings` | Fails when `Resources/Localizable.xcstrings` is stale against the source. |
| `make check-translations` | Fails when any key in **either** catalog — `Localizable.xcstrings` or `InfoPlist.xcstrings` — is missing a catalog language. Both release paths run it. |
| `make appstore-validate-copy` | App Store copy completeness and caption fit. |

Anything that must be verified against the *running* app belongs in the debug command channel, not in a unit test.

## Complexity budget

Every check above passes exactly as happily on a 400-line addition as on a 40-line one, so none of them constrains complexity. This section does, and it is as much a part of done as they are.

**The budget for a feature is zero new files and zero new types.** Fit it into whatever already owns the concern — the subsystem map says which that is. A new class, protocol, `*Rules.h` or directory is a request made *before* the code is written and argued on the feature's own terms; "it needs its own state machine" is the claim under question, not a reason for one.

**Say what the change removes.** Every feature reports its net line count, its new files, its new types, and either what it deleted or unified, or a plain statement that it consolidated nothing and why. A "nothing, because …" that reads badly is itself the finding: a feature that touches a subsystem and simplifies nothing in it is usually sitting in the wrong place.

**Deleting and rewriting are expected, not risks to be managed.** `make test`, the stress suites and git make them recoverable. Never keep a mechanism because it exists, because it was expensive to write, or because it is only *probably* dead — find out what reaches it, and if nothing does, remove it in the same change instead of leaving it beside the new path. Two mechanisms splitting one job is worse than either of them alone.

**Prefer the boring shape.** A branch in an existing method beats a strategy object; a field beats a state machine; a direct call beats a notification; a parameter beats a coordinator. Reach for machinery once the simple shape has been written and demonstrably fails — concurrency the call sites cannot see, a lifetime outliving its caller, a third caller that would otherwise copy the logic — never in anticipation of that.

**The consolidating pass is part of the feature, not a favor to the reader.** Once it works, re-read the whole file it landed in and fold the new code into what was already there. `/simplify` in a *fresh* session does this better than the session that wrote the code, which will defend it.

## Debugging and verification

Use the **`vibe-debug` skill** (`.claude/skills/vibe-debug/`) to launch, drive, inspect or screenshot either app. It is the canonical reference for the debug command channel (`Vibe --debug-cmd <command>`, debug builds only, `Vibe/Debug/`): state dumps, the view tree, menus, Now Playing, screenshots, transport/FX/UI driving, file opening, waveform-cache control, and the `scan_bpm`/`scan_key` analyzers that run in the CLI process with no app. It also covers the iOS simulator loop (`launch-ios.sh`, `debug-ios.sh`, `drive-ios.sh`), log streaming, and the launch-time build-provenance block.

Use the **`vibe-stress` skill** (`make stress CORPUS=<folder>`, `make torture PLAYLIST=<folder>`) for soak runs, leak and resource-growth hunting, TSan race hunting, fuzzing the file-loading path, and shrinking a failing run to a repro. It builds on the debug channel — read `vibe-debug` first.

Test audio: `Assets/test_audio_files/` (gitignored). If missing, generate with the `vibe-debug` skill's `generate-test-audio.sh` rather than synthesizing your own.

The command list lives in the skill and in the channel's own unknown-command reply, deliberately not here, so it cannot drift.

## Layout: the directory is the platform boundary

`project.yml` lists one recursive source entry per top-level shared subsystem and per macOS app-shell piece. A new one of those boundaries needs a new entry; a nested feature directory such as `Audio/Levels/` is already covered by its subsystem entry. Within that:

- Every directory directly under `Vibe/` except `Mac/`, `iOS/` and `ThirdParty/` is a **shared subsystem**, listed in both targets' sources.
- Inside any subsystem, `Mac/` and `iOS/` are the only platform markers: a path containing `Mac` compiles only into `Vibe`, a path containing `iOS` only into `VibeiOS`, a path containing neither into both.
- No source entry may exclude a feature-named path. The only excludes allowed are `**/.DS_Store`, `**/*.md`, `Mac/**`, `iOS/**`, plus `**/Info.plist` on a shell directory and a fixed list under `ThirdParty/`.

Consequences: **a new file in a shared directory joins the iOS target automatically**, so it must be AppKit-free or `TARGET_OS_OSX`-guarded. A shared source may not `#import` a header that only one platform's tree has, unguarded — Xcode's project-wide headermap resolves it by basename whatever the target membership, so it would compile and then fail at runtime or link.

`make check-layout` enforces all four assertions; CI's `build-ios` job catches an AppKit leak.

## Subsystem map

Nested `CLAUDE.md` files hold the detail and load only when you work under that directory. **Read the relevant one before changing anything it covers.**

**Documentation follows the same platform boundary as the code.** A shared subsystem's own `CLAUDE.md` covers only what both platforms have; anything specific to one platform belongs in a `CLAUDE.md` under that subsystem's `Mac/` or `iOS/` directory, beside the code it describes — so `Audio/CLAUDE.md` is the engine, `Audio/Mac/Devices/CLAUDE.md` is the HAL layer, and `Audio/iOS/CLAUDE.md` is the audio session. A `.md` file is excluded from every source entry in `project.yml`, so one can be added to any directory without touching the build.

- **`Vibe/Common/`** — what everything else is written in terms of: `AppSettings`, `Mac/AppTheme` (the theme record type and its one sanitization gate), `VibeStrings.h`, the prefix header, `DocumentTypes`, the `VibeImage`/`VibeColor` platform aliases and the bounded image decode. No feature lives here.
- **`Vibe/Audio/`** — playback engine, FX, waveform data, BPM/key analysis, conversion. `Mac/Devices/` is the CoreAudio HAL output-device layer, `Mac/Convert/` the FLAC encoder, and `iOS/` the AVAudioSession lifecycle and engine recovery.
- **`Vibe/Audio/Metadata/`** — tags, the disk cache, the two-stage scan, embedded and folder art.
- **`Vibe/Audio/Waveform/`** — waveform *data*: generation, chunking, persistence. **`Vibe/Audio/Analysis/`** — tempo and key detection riding that decode pass. **`Vibe/Audio/Levels/`** — demand-driven FFT levels from the live output graph; it never participates in file analysis.
- **`Vibe/System/`** — bridges to OS services that are neither audio engine nor app UI: Now Playing / remote commands, cloud download progress, cloud file materialization. Both platforms drive them.
- **`Vibe/Controls/`** — controls both platforms draw: `EqualizerIndicatorView`, the playing-row marker, and `LoadingIndicator`/`LoadingIndicatorView`, one control across the waveform's midline and the row gutter's pill. A control earns a place here only when both apps draw the *same* one.
- **`Vibe/Playlist/`** — the model and the CUE/M3U readers, shared; `Mac/` is the table.
- **`Vibe/WaveformUI/`** — waveform *rendering*: renderer strategies and the morph engine, shared; `Mac/` the `NSView`, `iOS/` the scrubber. Named apart from `Audio/Waveform/` deliberately — one makes the data, the other draws it.
- **`Vibe/Util/`** — featureless helpers, with `Mac/` and `iOS/` halves. **`Vibe/Debug/`** — the debug channel: shared transport, dispatch and common verbs, with `Mac/` and `iOS/` command tables.
- **`Vibe/Mac/`** — the macOS app shell, one directory per piece: `App/` (application object, open funnel, sandbox grants, stats), `MainWindow/` (`MainPlayerController`; layout and chrome are that directory's `APPEARANCE.md`), `Menu/`, `Controls/`, `Settings/`, `About/`.
- **`Vibe/iOS/`** — the iPhone/iPad app shell: `PlaybackController` (the model), a tab shell, mini player, and the full-screen now-playing card. The iOS halves of shared subsystems live under those subsystems, not here.
- **`Vibe/ThirdParty/`** — vendored TagLib subset and PINCache/PINOperation.

## Cross-directory guarantees

A **guarantee** is a condition the code must keep true, written once so a new call site can be checked against it. Each side is documented in its own directory; the coupling lives here.

**A guarantee is a cost, not an achievement.** Every bullet here is a rule each future change must be checked against, so the list is the running total of what has to be held in the head at once — and nothing about writing one creates pressure to retire one, which is how a list like this quietly becomes the design instead of describing it. Adding a bullet means first trying to remove a bullet: the change that needs a new rule can often retire an old one, two bullets stating one rule from different directories are one bullet, and a rule with a single call site belongs in that directory's own doc instead. The best version of a change deletes a guarantee.

- **Tag-over-analysis precedence.** A file's tagged tempo (`AudioTrackMetadata.bpm`) beats the analyzed one (`AudioTrack.detectedBPM`); tagged key likewise beats `detectedKey`. `AudioTrack.bpm` and `.key` are the single homes of both rules. Analysis is macOS-only, so on iOS the tagged half is the whole answer.
- **Embedded art beats folder art.** A file's own artwork always wins; a cover beside it (`FolderArtResolver`) fills in only for a file carrying none. Folder art is resolved per *directory*, lazily, off the metadata scan's path entirely, and is never persisted — the metadata cache is keyed by the audio file's size and mtime, which a sidecar image cannot move. A folder the app holds no *active* grant for is left untouched rather than probed: unasked-for background work must never raise a permission panel.
- **The equalizer bars follow the audio on both platforms, from one demand-driven analyzer tapped at whichever node feeds the output.** That node is not the same on each: with no FX segment — `enableFX:NO`, the iOS player — `mainMixerNode` is it, while with the segment present the reverb and delay returns re-enter *downstream* of that mixer, so the signal reaching the speaker is `AudioFX.masterBusOutputNode`. `applyLevelTapOnQueue` picks, which is also why macOS launched with FX switched off lands on the iOS wiring. The analyzer transforms up to two channels separately, combines their power rather than their samples, caps its highest band at 20 kHz and publishes coherent, sequenced five-band snapshots at a bounded rate independent of the display. Each shell hands its rows an `EqualizerLevelSource` (`PlaybackController` on iOS, `MainPlayerController` on macOS); a nil source is inactive, never synthetic animation.
- **The equalizer has no ongoing app-side wakeups or audio work while its audio or pixels are inactive**, and the chain that makes that true spans three directories. A view starts its poller only for modeled output audio *and* material presentation visibility, attachment, a source and nonempty geometry; a running poller declares one balanced `equalizerLevelsWanted:` consumer; each shell counts those consumers; the player's tap is absent at zero. So losing either half — the audio or the pixels — reaches all the way down to the FFT. Two definitions are load-bearing and belong to nobody else: **material visibility is each shell's own fold** (iOS: scene, selected tab, card coverage, row display; macOS: window occlusion and the row's real clip/window intersection), and **output audio is modeled, never guessed** — pending play intent alone is not output, any tracked outgoing fade still is, and since `AVAudioEngine` exposes no wet-tail liveness an FX tail after every source has stopped is not approximated with a timer. The renderer's poll and animation contract is `Controls/CLAUDE.md`'s, the producer and demand contract `Audio/Levels/CLAUDE.md`'s, the two visibility folds `Playlist/Mac/CLAUDE.md`'s and `iOS/CLAUDE.md`'s.
- **Three features are macOS-only, each switched off at one place rather than compiled out.** `FolderArtResolver` builds for both targets, but `AudioTrackArtwork` leaves its `folderArt` handle nil on iOS, so every folder-art accessor is a message to nil. The BPM and key analyzers build for both, but the decode pass asks a `VibeWaveformAnalysisProvider` (`AudioWaveformLoader.h`) that only macOS installs. The DJ FX graph is off by the `enableFX:NO` the iOS player is created with. All three settings are macOS-only in `AppSettings`, so iOS cannot read a preference it cannot act on.
- **The 128px thumbnail is for list rows.** Both platforms archive compact bytes per row and decode visible thumbnails through `AudioTrackArtwork`'s shared bounded cache — the mac playlist's art cells, the iOS library rows, the iOS mini player. The two big art surfaces — the mac header and the iOS now-playing page — deliberately draw none of it: each draws the display-art rendition archived beside the metadata entry, sized per platform to be quality-equivalent to the live full-art decode (640 mac, 1024 iOS — `Audio/Metadata/CLAUDE.md`), so a track change or page swipe never re-reads the audio file for art. Source-file extraction remains only the fallback for a missing sidecar.
- **A track is named on screen in one place.** `AudioTrack.displayTitle` and `.displayArtist` decide whether a row shows tagged title + artist or the filename-derived single line. A nil `displayArtist` means there is no second line to draw, not an empty one — **and that single line is still the TITLE, so it takes the title's colour on both platforms.** The mac row drew it in the artist's dimmer colour instead, which made a file carrying a real title but no artist tag read as an untagged filename, and disagreed with iOS drawing the same value in `labelColor`.
- **The open the user is waiting on outranks every background read that would download a file.** On a file-provider folder the scarce thing is the provider's transfer. The rule lives in one object: `AudioFileMaterializationCoordinator` derives "a foreground transfer is active" from its own claim table (any live claim with a playback or prefetch waiter), yields known metadata-only dataless claims when foreground registration rises — the sweep's in-flight download is cancelled, not waited out — and makes outstanding classifications recheck the hold before entering a provider operation. Admission reopens at the settlement every path already funnels through, so no external release edge exists to be missed or doubled, on any platform. **A file already local is exempt throughout** — the rule and the transfer lanes bound provider *downloads*, which a local file never starts — so local tags and art keep landing while a cloud open has the wire to itself. Each shell also **defers** the sweep's start until the picked track's open settles (`scheduleDeferredMetadataLoad`, both platforms), which is a scheduling nicety on top of the rule and not the rule. The coordinator's half is `Audio/CLAUDE.md`'s; how the sweep asks `isForegroundTransferActive`, retries and re-ranks against it is `Audio/Metadata/CLAUDE.md`'s.
- **The handle-open ceiling is derived from one player and its three open sources.** Both shells keep one production `AudioPlayer` per process; its queue-confined playback, prefetch and gapless token slots give the conservative three-source bound. The coordinator permits six purpose/path memberships, leaving room for three stranded calls in aggregate while bounding uncancellable `AVAudioFile` workers. The ceiling is purpose-blind and that margin is not reserved: prefetch or gapless may consume all six, in which case a later playback key is refused rather than starting a seventh worker. Adding another production player or open source, or making a source multi-flight, requires re-deriving the ceiling and its tests. The coordinator mechanics live in `Audio/CLAUDE.md`.
- **A folder opens in one order, chosen by the shell and applied by the walk.** `AppSettings.folderOpenSort` (Settings > Files > When opening a folder on macOS, its own section on iOS) is sort-by-name, newest-modified-first, or keep-folder-order. `NSURLUtil` is a path utility and may not read a setting (`Util/CLAUDE.md`), so each shell reads it on main with the rest of its open snapshot — `AppDelegate.openURLsWithRestoredAccess:token:`, and `FolderSession`'s three entry points — and passes it to `expandAndFilterList:sortedBy:` or `audioFilesInDirectory:sortedBy:`. The order therefore cannot change under an open in flight, and it reaches only what the walk *expanded*: the top-level URLs the user gave keep their order, and a playlist file keeps its list order, under every choice. There is no live apply, because the setting governs the next open rather than the playlist on screen.
- **Async deliveries race track changes.** Waveform, BPM, key and metadata deliveries can arrive after the track has changed, so a receiver must match the delivered URL or track against the current one before applying it.
- **A play's settlement is matched by submission identity, not by track.** `didStartPlaying:` and the play-path errors are dropped by the player when a newer play has been submitted before they reach main (`AudioPlayer.submittedPlayIsCurrent:`). URL and track cannot decide it: replaying the **same row** produces the same `AudioTrack` and the same URL, so a settlement belonging to the previous play passes every content-based guard — and acting on it tears down state the newer play has already set up.
- **The waveform theme always beats the style's built-in palette, and is resolved in one place.** The style setting is the geometry, the theme the colors; `WaveformTheme` (`Vibe/WaveformUI/`) is the only home of the identifier-to-colors rules. Each theme color carries its side's resting level in its alpha and renderers keep only their ramp shapes, which is what keeps the default Mono theme (stored identifier `mono`) pixel-identical to the pre-theme monochrome look, and the Orange theme on Sonic Cirrus's bars identical to the pre-theme Sonic Cirrus. Each view resolves it — settings + appearance + the settled artwork color, with the custom theme storing a color pair per appearance — and re-resolves on an appearance flip, because every rule branches on dark. Sonic Cirrus keeps its orange across the split by a one-time migration: a stored `sonic_cirrus` style with no theme key gets `orange` written at init (`SettingsRules.h`). **The `album_art` color rides the artwork install path on both platforms**, which is what closes the async-delivery race: on macOS `ArtworkDisplayController` fires its handler only for a target-matched install, and on iOS the color is derived from the very image a page was just handed (`TrackPageCell`), so a stale delivery can never color the wrong track's waveform. The extraction itself is one function, `VibeDominantColorOfImage` (`Common/PlatformImage.h`), so the two platforms cannot disagree about what a cover's color is. **The color is per view, not per app**: the iOS pager shows a different track on every page, and one shared color would paint the whole pager with whatever happened to be playing — which is why `WaveformScrubberView`'s theme signature folds its own artwork color in. A track with no art resolves to Mono's answer, as does art too gray to yield a hue.
- **Every themed appearance choice reads `AppSettings.currentTheme`, and every edit of it funnels through `currentThemeDidChange`.** A theme is a sparse record over the factory defaults (`AppTheme`, `Common/Mac/CLAUDE.md`), so the built-in Vibe theme is the empty record and cannot drift from the factory look; every store mutation refuses a built-in, and a casual toggle over one — View > Show File Info while Vibe is active — lands in the divergence key, surviving relaunch without dirtying the built-in, until re-applying a theme resets it. The store never applies effects: the writer requests the mapped `VibeSettingsLiveEffect` (`ThemeApply` for a whole-theme switch), the same store-first contract as every other setting. Sanitization is one gate on `AppTheme`, so a JSON import, a stored record and a UI edit are held to the same clamps. **A theme's colors are single-mode or dual-mode** (`AppTheme.mode`: `single`/`dual`, factory `dual` — the built-in Vibe theme carries a light and a dark palette). Dual keeps a color set per appearance and follows whichever the window has; single keeps ONE color per field and always uses it, whatever the system or the appearance setting says — the dark-keyed half is its one slot, read and written from either side, while the light-keyed halves lie dormant so a mode flip round-trips losslessly. The window's appearance itself is `AppSettings.windowAppearanceStyle` (Auto/Light/Dark, default Auto), a common setting deliberately outside the theme along with `showTrafficLights` — **except that a single-mode theme with a solid background outranks it** (`requiredWindowAppearance`): the window pins to the side the background color's luminance reads as, so a white single theme keeps light chrome, light materials and dark default labels in every mode. macOS-only — iOS keeps its loose shared keys, a separate app over a separate store.
- **A `VibeMusicalKey` of 0 is C major, not "none".** Every fresh holder must be set to `VibeMusicalKeyNone` (-1) explicitly — a zero-filled ivar or a message to nil reads as tagged C major.
- **"On track end" is enforced once per way a track end can advance, and there are two.** `AppSettings.pauseAtTrackEnd` (Settings > Playback, macOS-only) decides whether a track end advances. The audio can advance itself: every prefetch site asks `MainPlayerController.successorPrefetchTrack` for the track to park, and it answers nil under Pause, so the player has no parked handle to arm its gapless splice with. The shell can advance it: `advanceOrParkAtTrackEnd` reads the setting again before calling `next:`, because it decides from the playlist alone and never consults what was parked — a track end that reaches `didFinishPlaying:` would otherwise advance mid-playlist whatever the prefetch did. Both reads are load-bearing; deleting either, adding a prefetch call site that reaches past `successorPrefetchTrack`, or writing the setting without requesting `VibeSettingsLiveEffectEndOfTrack` breaks the setting rather than merely a latency win.
- **Editing the playlist's structure is a model edit plus a shell transport decision, and the model half deliberately cannot make the second.** `Playlist.removeTracksAtIndexes:`, its undo inverse `insertTracks:atIndexes:` and `moveTracksAtIndexes:toIndexes:` are all batch-shaped — a single row is the one-index case, so no parallel single-row path exists — and all three move rows, rebuild both indexes and touch no audio: removing the *current* row through the model alone would leave the player sounding an object the playlist no longer contains. Every removal gesture — selection-wide now that the table multi-selects — funnels the exact `AudioTrack`s through `MainPlayerController.removePlaylistTracks:`, which owns the consequences: the whole-selection unload via `closeFile:`, the successor re-prefetch through `successorPrefetchTrack` (the same single prefetch funnel the On-track-end bullet above depends on), the replacement play carrying the ordered intent, and the generation-stamped undo registration whose restore dies quietly once the playlist it edited is replaced. A **move** — the table's internal drag, token-fenced and identity-resolved so a stale drag dies rather than moving strangers — is transport-safe at the model boundary because the current object survives; its whole shell follow-up is `playlistOrderDidChangeHandler` (undo registration, re-park, neighborhood, UI), it never enters a play funnel, and it undoes through its own inverse — the set-to-set model op with the sets swapped, registered by that same handler on every move so undo and redo chain themselves. **The files are never touched.** One structural edit sends **one** observer event; the mac reconciles it once with precise row operations, never `reloadData`, and iOS implements all three observer methods as no-ops because it exposes no transport-safe removal or reorder path. The landing rules, race fallbacks and undo contract are `Mac/MainWindow/CLAUDE.md`'s; the cursor and index rules `Vibe/Playlist/CLAUDE.md`'s; the drag and slot arithmetic `Playlist/Mac/CLAUDE.md`'s and `PlaylistDragRules.h`'s.
- **`AudioPlayer.stop` fires no delegate callback.** It is not a track-end event, so it must never drive auto-advance, and the caller owns the UI reset. Track-end and skip-past-end both funnel through `didFinishPlaying:`.
- **A row shows the loading bar only while a provider transfer is actually running for its file.** `AudioFileMaterializationCoordinator` publishes begin/end to `CloudTransferRegistry` only when its accepted initial or start-refresh classification says the file is dataless. A local file — whose operation is a no-op coordinated read — therefore publishes nothing, and a claim merely queued behind lane capacity publishes nothing either. Lane capacity bounds the indicators as well as the transfers: dropping a large cloud folder marks the one to three files on the wire and leaves every other row its number. The playing row's fraction comes from the shell's own open-request-identified monitor via `noteProgress:forURL:`, so no file is watched by two monitors. In the gutter, loading outranks the playing marker — during the open there is no output audio, so the equalizer would be collapsed dots. The registry is `Audio/CLAUDE.md`'s; the row wiring is `Playlist/Mac/CLAUDE.md`'s and `iOS/CLAUDE.md`'s; the control is `Controls/CLAUDE.md`'s.

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

Behavior added to a foreign class is a category (`NSURL+Hash`, `PINCache+VibeAudioCache`), never a free function taking that class as its first argument. The exceptions are both in `Common/`, and both for the same reason — the class involved differs per target, so there is no single one to hang on: `PlatformImage.h`'s bounded decode, which *constructs* an `NSImage` or a `UIImage`, and `PlatformColor.h`'s hex and blend functions over `VibeColor`.

**`Coordinator` is deliberately generic** and names three different contracts: `PlaybackRequestCoordinator` is request identity, `MetadataParseCoordinator` is single-flight ownership, `OpenRequestCoordinator` is ordered delivery. A fourth needs saying which it is.

`make check-vocabulary` enforces six mechanical rules, and it is the authority on what is checkable:

1. No bare `_generation` ivar — spell it `<protectedThing>Generation`.
2. No `DefaultAppClaim` — OS role registration is `registration`.
3. Every header-only `static inline` file with no `.m`/`.mm` beside it must be `*Rules.h` or `*Math.h`, unless it is on the script's allowlist of non-seam headers (`AudioPlayerInternal.h`, `HelperMacros.h`, `MusicalKey.h`, `PlaybackIntent.h`, `VibeStrings.h`).
4. **No `#if DEBUG` in a shipping header.** Debug surface is a declaration-only category under `Vibe/Debug/`. There is no allowlist. A debug-only property ships as a pointer; debug-only *state* belongs to a debug-only object the shipping class holds (`VibeManualRenderPump`).
5. The trap marker is spelled `TRAP:` and nothing else, so `grep -rn 'TRAP:' Vibe` is the complete list of things that bite.
6. No `invariant`, in code or in a directory doc — a condition the code must keep true is a `guarantee`, so one grep finds them all.

## Logging

`LogError`, `LogWarn`, `LogInfo`, `LogDebug` in `Vibe-Prefix.pch` wrap `os_log` under the subsystem `com.commonwealthrecordings.Vibe`. Info and debug are **not persisted**, so they must be streamed live — see the `vibe-debug` skill.

## Localization

**Every user-facing string is declared in `Vibe/Common/VibeStrings.h` and nowhere else.** Call sites use a `STR_*` macro and nothing more — no key, no English text, no translator comment inline.

Keys are symbolic and stable (`menu.file`, `label.bpm`), never the English text; the English lives in the macro's default value. **`make strings` after touching any UI string**; `make check-strings` fails when the catalog is stale. English is the source language; read the language list from `Resources/Localizable.xcstrings` rather than hardcoding it.

**Display names are never identifiers** — the registry key, the `NSUserDefaults` value and a menu item's identifier stay separate from the localized label.

The **`vibe-strings` skill** is the reference for the `NSLS` registry conventions, the extraction pipeline and its `extractionState` rules, `InfoPlist.xcstrings`, translation terminology, the pseudolocale audit and the localized App Store product page. Read it before editing `VibeStrings.h`, the catalogs or `scripts/extract-strings.sh`.

## Key patterns

- **No private APIs, ever.** This app ships in the Mac App Store. Do not call, override or depend on undocumented selectors, classes or notifications — overriding a private method such as `resignKeyAppearance` counts, even though it compiles without any private declaration. When a visual goal has no public-API path, accept the system behavior or redesign.
- **Deployment targets are macOS 13.0 and iOS 26.0.** `CLANG_WARN_UNGUARDED_AVAILABILITY: YES_AGGRESSIVE` is on, so anything newer than the floor needs an `@available` guard — the Liquid Glass chrome is guarded on macOS 26 with a pre-26 fallback, and the equalizer's `CADisplayLink` poller on macOS 14 with a timer fallback. Every such path sits behind `@available(macOS …)` — never `#if` or an OS-version check — so `grep -rn '@available(macOS' Vibe` is the complete inventory of version-specific code.
- **Singletons**: `AppSettings`, `AppStats`, `AudioDeviceManager` (macOS), `FolderAccessManager` (macOS), `FolderArtResolver`, `Formatters`.
- **File hashing**: `NSURL+Hash.cacheKey` supplies the cache key for metadata and waveform data — `<size>-<mtime_us>-<sha1(resolved path)>`, from file attributes alone. It resolves symlinks first (`attributesOfItemAtPath:` does not traverse them) and returns nil rather than a degenerate key when the stat fails. Hashing no content keeps it cheap but misses a rewrite or a move.
- **ObjC++ (.mm files)** appear only where C++ is genuinely needed: the TagLib integration, the waveform data structures and the renderers. Keep C++ types out of headers that plain ObjC files import.
- **Comments only when required, and terse.** A comment earns its place by stating what the code cannot show: a trap, an ordering or threading constraint, a contract, a non-obvious why. Most code needs none. Never narrate what the next line does, and never log a change — "renamed from", "added in", "moved here" and how something was verified all belong in commits. **Naming the bug a design prevents is not change-logging and is welcome**: "the fall-through used to be YES, which let a mistyped item skip validation" is the most concrete form a non-obvious why takes, and the reason it survives a rewrite. Mark hard-won traps with `TRAP:`.
- **A trap may be written twice, and the code comment is the authority.** The directory's `CLAUDE.md` carries a trap so it is read while *planning* work there; the `TRAP:` beside the code carries it so it is read while *changing* that line. Roughly a third of them are in both places on purpose. The cost is that fixing one copy strands the other, so **changing a trap means changing both** — `grep -rn 'TRAP:' Vibe` reaches every copy, doc and code alike.
- **Third-party sources** in `ThirdParty/` are other authors' code. Do not restyle them.

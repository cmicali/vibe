# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

Vibe is a native music player for macOS (`Vibe` target) and iOS (`VibeiOS` target), written in Objective-C and Objective-C++. Playback is Apple frameworks only — `AVAudioEngine` and CoreAudio, no third-party audio library. Formats: MP3, MP2, AAC, AIFF/AIF, WAV/WAVE/BWF, FLAC, M4A, MP4, QTA (`Common/PlayableExtensions`, the one home of the set). OGG is not supported.

## Building

`Vibe.xcodeproj` is generated from `project.yml` by XcodeGen and is **not** checked in. Regenerate after cloning, after pulling and after every edit to `project.yml`: `xcodegen generate` (or `make project`). Every `make` target below regenerates first. The Makefile comments each target; the traps are here.

| Command | What it does |
| --- | --- |
| `make build [CONFIG=Debug]` | macOS app; Release by default, into `build/DerivedData`. |
| `make build-ios [CONFIG=Debug]` | iOS app, generic simulator destination, unsigned. Exactly CI's `build-ios` job. |
| `make install-ios [CONFIG=Debug]` | iOS app onto a paired device, signed. `DEVICE=<name or id>` when more than one is paired. |
| `make run` / `make install` | Launch; copy into `/Applications`. |
| `make clean` | Removes `build/` and the generated project. |
| `make reset-state [ARGS=-n]` | Wipes Vibe's persisted state (macOS container; `--both` adds the simulator app). Prompts; `-n` previews. |

**Debug builds are what the debug command channel needs** — it compiles out of Release entirely.

Releases go through the **`vibe-release` skill**: the Developer ID path (`make release`) and the App Store path (`make appstore-build`, `make appstore-upload-signed-build`) are not interchangeable — do not improvise from the scripts.

There is no package manager. TagLib and PINCache/PINOperation are vendored under `Vibe/ThirdParty/` and compile into both app targets.

## Checks

All of these run in CI (`.github/workflows/build.yml`).

| Command | Gate |
| --- | --- |
| `make test` | Host-less unit and orchestration tests (`Tests/`, always Debug) plus the cloud-runner oracle tests. **Read `Tests/CLAUDE.md` before adding to it.** |
| `make test-audio` | Real player/FX graphs in offline manual rendering, full PCM comparisons and signal-quality checks; no app or audio device. See `Tests/CLAUDE.md`. |
| `make test-summary` | Markdown pass/fail table from the last `make test`. |
| `make analyze CONFIG=Release` | clang static analyzer over **both** app targets; fails on any finding outside `ThirdParty/`. Findings are config-dependent — Release is what CI checks. |
| `make check-layout` | The layout rule below. |
| `make check-vocabulary` | The mechanical vocabulary rules below. |
| `make check-strings` | Fails when `Resources/Localizable.xcstrings` is stale against the source. |
| `make check-translations` | Fails when any key in any catalog is missing a language. Both release paths run it. |
| `make appstore-validate-copy` | App Store copy completeness and caption fit. |

Anything that must be verified against the *running* app belongs in the debug command channel, not in a unit test.

## Complexity budget

Every check above passes as happily on a 400-line addition as on a 40-line one, so none of them constrains complexity. This section does, and it is as much a part of done as they are.

**The budget for a feature is zero new files and zero new types.** Fit it into whatever already owns the concern — the subsystem map says which. A new class, protocol, `*Rules.h` or directory is a request made *before* the code is written and argued on the feature's own terms; "it needs its own state machine" is the claim under question, not a reason for one.

**Say what the change removes.** Every feature reports its net line count, new files, new types, and either what it deleted or unified or a plain statement that it consolidated nothing and why. A "nothing, because …" that reads badly is itself the finding: a feature that touches a subsystem and simplifies nothing in it is usually in the wrong place.

**Deleting and rewriting are expected, not risks to be managed.** `make test`, the stress suites and git make them recoverable. Never keep a mechanism because it exists, was expensive to write, or is only *probably* dead — find out what reaches it, and if nothing does, remove it in the same change. Two mechanisms splitting one job is worse than either alone.

**Prefer the boring shape.** A branch in an existing method beats a strategy object; a field beats a state machine; a direct call beats a notification; a parameter beats a coordinator. Reach for machinery only once the simple shape has been written and demonstrably fails — never in anticipation.

**The consolidating pass is part of the feature.** Once it works, re-read the whole file it landed in and fold the new code into what was already there. `/simplify` in a *fresh* session does this better than the session that wrote the code.

## Debugging and verification

The **`vibe-debug` skill** launches, drives, inspects and screenshots either app. It is the reference for the debug command channel (`Vibe --debug-cmd <command>`, debug builds only, `Vibe/Debug/`), the iOS simulator loop, log streaming and the launch-time build-provenance block. The command list lives in the skill and in the channel's own unknown-command reply, deliberately not here.

The **`vibe-stress` skill** (`make stress`, `make torture`) is soak runs, leak and resource-growth hunting, TSan race hunting, fuzzing the file-loading path, and shrinking a failing run to a repro. Read `vibe-debug` first.

Test audio: `Assets/test_audio_files/` (gitignored). If missing, generate with the `vibe-debug` skill's `generate-test-audio.sh` rather than synthesizing your own.

## Layout: the directory is the platform boundary

`project.yml` lists one recursive source entry per top-level shared subsystem and per macOS app-shell piece; a nested feature directory is already covered by its subsystem entry. Every directory directly under `Vibe/` except `Mac/`, `iOS/` and `ThirdParty/` is a shared subsystem compiled into both targets, and within one `Mac/` and `iOS/` are the only platform markers.

Consequences: **a new file in a shared directory joins the iOS target automatically**, so it must be AppKit-free or `TARGET_OS_OSX`-guarded. A shared source may not `#import` a header that only one platform's tree has, unguarded — Xcode's project-wide headermap resolves it by basename whatever the target membership, so it compiles and then fails at runtime or link.

`make check-layout` enforces the rule — its header states the four assertions, and it, not this prose, is the authority; CI's `build-ios` job catches an AppKit leak.

## Subsystem map

Nested `CLAUDE.md` files hold the detail and load only when you work under that directory. **Read the relevant one before changing anything it covers.** Documentation follows the platform boundary: a shared subsystem's doc covers what both platforms have, and anything platform-specific lives in a doc under that subsystem's `Mac/` or `iOS/` directory. `.md` files are excluded from every source entry, so a doc can be added anywhere without touching the build.

- **`Vibe/Common/`** — what everything else is written in terms of: `AppSettings` (its macOS half, the theme store included, is `Mac/`; `Mac/Theme/` is the `AppTheme` record, its one sanitization gate, the archive form and the dice), `VibeStrings.h`, the prefix header, `DocumentTypes`, the `VibeImage`/`VibeColor` aliases and the bounded image decode. No feature lives here.
- **`Vibe/Audio/`** — playback engine, FX, waveform data, BPM/key analysis, conversion. `FX/` (the DJ master-bus segment, optional per player via `enableFX:`), `Loading/` (the file-open path: the materialization claim, admission and the handle-run ceiling, `CloudTransferRegistry`), `Metadata/` (tags, cache, scan, embedded art; `FolderArt/` is the sidecar-cover fallback), `Waveform/` (data), `Analysis/` (tempo and key), `Levels/` (live FFT levels from the output graph), `Mac/Devices/` (CoreAudio HAL output devices), `Mac/Convert/` (FLAC encoder), `iOS/` (audio session and engine recovery) each have a doc.
- **`Vibe/System/`** — bridges to OS services: Now Playing and remote commands, cloud download progress, cloud file materialization. Both platforms drive them.
- **`Vibe/Controls/`** — controls both platforms draw the *same* way: the equalizer bars, the playing-row marker, the loading indicator.
- **`Vibe/Playlist/`** — the model and the CUE/M3U readers; `Mac/` is the table.
- **`Vibe/WaveformUI/`** — waveform *rendering*: `WaveformTheme` and the iOS zoom floor, shared; `Renderers/` the strategies, the morph engine and the level mapping; `Mac/` the `NSView`, `iOS/` the scrubber. Named apart from `Audio/Waveform/` deliberately — one makes the data, the other draws it.
- **`Vibe/Util/`** — featureless helpers, with `Mac/` and `iOS/` halves. **`Vibe/Debug/`** — the debug channel, with `Mac/` and `iOS/` command tables.
- **`Vibe/Mac/`** — the macOS app shell, one directory per piece: `App/` (application object, open funnel, sandbox grants, stats, the debug info report), `MainWindow/` (`MainPlayerController`; layout and chrome are its `APPEARANCE.md`; `Transport/` and `Convert/` carry their own docs), `Menu/`, `Controls/`, `Settings/` (`Appearance/` is the theme list and editor), `About/`.
- **`Vibe/iOS/`** — the iPhone/iPad app shell: `PlaybackController` (the model), the tab shell and mini player; `Player/` is the now-playing card, `Search/` Favorites and search, `Settings/` the settings screens, each with a doc. The iOS halves of shared subsystems live under those subsystems, not here.
- **`Vibe/ThirdParty/`** — vendored TagLib subset and PINCache/PINOperation.

## Cross-directory guarantees

A **guarantee** is a condition the code must keep true, written once so a new call site can be checked against it. Each side is documented in its own directory; the coupling lives here.

**A guarantee is a cost, not an achievement.** Every bullet is a rule each future change is checked against, so the list is the running total of what must be held in the head at once. Adding a bullet means first trying to remove one: the change that needs a new rule can often retire an old one, two bullets stating one rule from different directories are one bullet, and a rule with a single call site belongs in that directory's own doc. The best version of a change deletes a guarantee.

- **Tag-over-analysis precedence.** A tagged tempo (`AudioTrackMetadata.bpm`) beats the analyzed one (`AudioTrack.detectedBPM`); tagged key likewise beats `detectedKey`. `AudioTrack.bpm` and `.key` are the single homes of both rules. Analysis is macOS-only, so on iOS the tagged half is the whole answer.
- **Embedded art beats folder art.** A file's own artwork always wins; a cover beside it (`FolderArtResolver`) fills in only for a file carrying none. Folder art is resolved per directory, lazily, off the metadata scan's path, and never persisted — the metadata cache is keyed by the audio file's size and mtime, which a sidecar image cannot move. A folder with no *active* grant is left untouched: unasked-for background work must never raise a permission panel.
- **The equalizer bars follow the audio, from one demand-driven analyzer tapped at whichever node feeds the output.** With no FX segment (`enableFX:NO`, the iOS player) that is `mainMixerNode`; with it, the reverb and delay returns re-enter downstream, so it is `AudioFX.masterBusOutputNode`. `applyLevelTapOnQueue` picks. The analyzer combines channels by power, caps its top band at 20 kHz and publishes sequenced five-band snapshots at a bounded rate. Each shell hands its rows an `EqualizerLevelSource`; a nil source is inactive, never synthetic animation.
- **The equalizer has no ongoing wakeups or audio work while its audio or pixels are inactive.** A view starts its poller only for modeled output audio *and* material visibility, attachment, a source and nonempty geometry; a running poller declares one balanced `equalizerLevelsWanted:` consumer; each shell counts consumers; the player's tap is absent at zero. **Material visibility is each shell's own fold** (`Playlist/Mac/CLAUDE.md`, `iOS/CLAUDE.md`), and **output audio is modeled, never guessed**: pending play intent is not output, a tracked outgoing fade still is, and an FX tail after every source stopped is not approximated with a timer. The renderer contract is `Controls/CLAUDE.md`'s, the producer contract `Audio/Levels/CLAUDE.md`'s.
- **Three features are macOS-only, each switched off at one place rather than compiled out.** Folder art: `AudioTrackArtwork` leaves its `folderArt` handle nil on iOS. BPM and key analysis: only macOS installs a `VibeWaveformAnalysisProvider`. The DJ FX graph: the iOS player is created with `enableFX:NO`. All three settings are macOS-only in `AppSettings`.
- **The 128px thumbnail is for list rows.** Both platforms decode row thumbnails through `AudioTrackArtwork`'s shared bounded cache. The two big art surfaces — the mac header and the iOS now-playing page — draw the display-art rendition archived beside the metadata entry (640 mac, 1024 iOS; `Audio/Metadata/CLAUDE.md`), never the thumbnail, so a track change never re-reads the audio file for art.
- **A track is named on screen in one place.** `AudioTrack.displayTitle` and `.displayArtist` decide between tagged title + artist and the filename-derived single line. A nil `displayArtist` means no second line, and **the single line is still the TITLE, so it takes the title's colour on both platforms.**
- **The open the user is waiting on outranks every background read that would download a file.** `AudioFileMaterializationCoordinator` derives "a foreground transfer is active" from its own claim table, yields metadata-only dataless claims when foreground registration rises (the sweep's download is cancelled, not waited out), and rechecks the hold before entering a provider operation. **A file already local is exempt throughout.** Each shell also defers the sweep's start until the picked track's open settles (`scheduleDeferredMetadataLoad`), a nicety on top of the rule. The coordinator's half is `Audio/Loading/CLAUDE.md`'s; how the sweep retries and re-ranks against `isForegroundTransferActive` is `Audio/Metadata/CLAUDE.md`'s.
- **The handle-open ceiling is derived from one player and its three open sources.** One production `AudioPlayer` per process, with playback, prefetch and gapless slots, gives the three-source bound; the coordinator permits six purpose-blind memberships, so prefetch or gapless may consume all six and a later playback key is refused rather than starting a seventh worker. Adding a player or an open source, or making a source multi-flight, means re-deriving the ceiling and its tests (`Audio/Loading/CLAUDE.md`).
- **A folder opens in one order, chosen by the shell and applied by the walk.** `AppSettings.folderOpenSort` is read on main with the rest of the open snapshot (`AppDelegate.openURLsWithRestoredAccess:token:`; `FolderSession`'s open prologue, `beginOpenURLs:…`) and passed to the walk, which reads no setting (`Util/CLAUDE.md`). It reaches only what the walk *expanded*: the user's top-level URLs and a playlist file's order are kept. There is no live apply.
- **Async deliveries race track changes.** Waveform, BPM, key and metadata deliveries can arrive after the track has changed, so a receiver must match the delivered URL or track against the current one before applying it.
- **A play's settlement is matched by submission identity, not by track.** `didStartPlaying:` and the play-path errors are dropped when a newer play has been submitted (`AudioPlayer.submittedPlayIsCurrent:`). Replaying the **same row** produces the same `AudioTrack` and URL, so a content-based guard would pass a settlement belonging to the previous play.
- **The waveform theme always beats the style's built-in palette, and is resolved in one place.** The style is the geometry, the theme the colors; `WaveformTheme` (`Vibe/WaveformUI/`) is the only home of the identifier-to-colors rules, and each color carries its side's resting level in its alpha. Each view resolves settings + appearance + the settled artwork color, and re-resolves on an appearance flip. **The `album_art` color rides the artwork install path on both platforms**, which closes the delivery race (a target-matched install on macOS, the very image a page was handed on iOS), and the extraction is one function, `VibeDominantColorOfImage`. **The color is per view, not per app**, since the iOS pager shows a different track on every page. No art, or art too gray, resolves to Mono's answer.
- **Every themed appearance choice reads `AppSettings.currentTheme`, and every edit funnels through `currentThemeDidChange`.** A theme is a sparse record over the factory defaults (`AppTheme`, `Common/Mac/Theme/CLAUDE.md`), so the built-in Vibe theme is the empty record; every store mutation refuses a built-in, and a casual toggle over one lands in the divergence key until a theme is re-applied. The store never applies effects: the writer requests the mapped `VibeSettingsLiveEffect`. Sanitization is one gate on `AppTheme`, held to by imports, stored records, UI edits and the built-ins shipped as `Resources/Themes/*.json` (validated by `make test`). A theme is `single` or `dual` mode: dual keeps a palette per appearance; single keeps one color per field in the dark-keyed slot and **outranks `AppSettings.windowAppearanceStyle`** by pinning the window dark (`requiredWindowAppearance`). macOS-only.
- **A `VibeMusicalKey` of 0 is C major, not "none".** Every fresh holder must be set to `VibeMusicalKeyNone` (-1) explicitly — a zero-filled ivar or a message to nil reads as tagged C major.
- **"On track end" is enforced once per way a track end can advance, and there are two, on each shell.** `AppSettings.pauseAtTrackEnd`, shared; `VibePlaybackShouldAdvanceAtTrackEnd` is the one rule both reads use. The audio: every prefetch site asks its shell's `successorPrefetchTrack` (`MainPlayerController` on the mac, `PlaybackController` on iOS), which answers nil under Pause, so no gapless splice is armed. The shell: the mac's `advanceOrParkAtTrackEnd` and the iOS `didFinishPlaying:` read the setting again before `next`, because they decide from the playlist alone. Both reads are load-bearing; a prefetch call site that bypasses `successorPrefetchTrack`, or a writer that skips the re-park (`VibeSettingsLiveEffectEndOfTrack` on the mac, `PlaybackController.applyTrackTransitionSettings` on iOS), breaks the setting.
- **Editing the playlist's structure is a model edit plus a shell transport decision, and the model half cannot make the second.** `Playlist.removeTracksAtIndexes:`, `insertTracks:atIndexes:` and `moveTracksAtIndexes:toIndexes:` are batch-shaped, move rows, and touch no audio. Every removal funnels the exact `AudioTrack`s through `MainPlayerController.removePlaylistTracks:`, which owns the unload, the re-prefetch through `successorPrefetchTrack`, the replacement play and the generation-stamped undo. A **move** is transport-safe at the model boundary because the current object survives; its whole follow-up is `playlistOrderDidChangeHandler`. **The files are never touched.** One structural edit sends one observer event; the mac reconciles it with precise row operations, never `reloadData`; iOS implements the three observer methods as no-ops. Landing rules and undo are `Mac/MainWindow/CLAUDE.md`'s; cursor and index rules `Playlist/CLAUDE.md`'s; drag and slot arithmetic `Playlist/Mac/CLAUDE.md`'s.
- **`AudioPlayer.stop` fires no transport or track-end callback.** It must never drive auto-advance, and the caller owns the UI reset. Track-end and skip-past-end both funnel through `didFinishPlaying:`.
- **A row shows the loading bar only while a provider transfer is actually running for its file.** `AudioFileMaterializationCoordinator` publishes to `CloudTransferRegistry` only when its accepted classification says the file is dataless; a local file and a claim queued behind lane capacity publish nothing, so dropping a large cloud folder marks only the files on the wire. The playing row's fraction comes from the shell's own monitor via `noteProgress:forURL:`, so no file is watched twice. In the gutter, loading outranks the playing marker. Registry: `Audio/Loading/CLAUDE.md`; row wiring: `Playlist/Mac/CLAUDE.md` and `iOS/CLAUDE.md`; control: `Controls/CLAUDE.md`.

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

**Suffixes.** `Vibe` prefixes C-linkage symbols; ObjC classes never carry it. Header-only files of `static inline` logic — the testable seams — are `*Rules.h` when they return a decision and `*Math.h` when they return a number in the problem's units; nothing else.

Behavior added to a foreign class is a category (`NSURL+Hash`), never a free function taking that class first. The two exceptions are in `Common/` because the class differs per target: `PlatformImage.h`'s bounded decode and `PlatformColor.h`'s hex and blend functions.

**`Coordinator` is deliberately generic** and names three contracts: `PlaybackRequestCoordinator` is request identity, `MetadataParseCoordinator` single-flight ownership, `OpenRequestCoordinator` ordered delivery. A fourth must say which it is.

`make check-vocabulary` enforces six mechanical rules and is the authority on what is checkable:

1. No bare `_generation` ivar — spell it `<protectedThing>Generation`.
2. No `DefaultAppClaim` — OS role registration is `registration`.
3. Every header-only `static inline` file with no `.m`/`.mm` beside it must be `*Rules.h` or `*Math.h`, unless it is on the script's allowlist of non-seam headers.
4. **No `#if DEBUG` in a shipping header.** Debug surface is a declaration-only category under `Vibe/Debug/`; there is no allowlist. A debug-only property ships as a pointer; debug-only *state* belongs to a debug-only object the shipping class holds (`VibeManualRenderPump`).
5. The trap marker is spelled `TRAP:` and nothing else, so `grep -rn 'TRAP:' Vibe` is the complete list of things that bite.
6. No `invariant`, in code or in a doc — a condition the code must keep true is a `guarantee`, so one grep finds them all.

## Logging

`LogError`, `LogWarn`, `LogInfo`, `LogDebug` in `Vibe-Prefix.pch` wrap `os_log` under `com.commonwealthrecordings.Vibe`. **`VIBE_VERBOSE_LOGGING` (`project.yml`) decides whether info and debug are kept**: at 1, the beta setting, every level is written at Default, so Settings > Advanced > Save Debug Info and `log show` retrieve it after the fact; at 0, the stable-release setting, info and debug are not persisted and must be streamed live — see the `vibe-debug` skill.

## Localization

**Every user-facing string is declared in `Vibe/Common/VibeStrings.h` and nowhere else.** Call sites use a `STR_*` macro and nothing more. Keys are symbolic and stable (`menu.file`, `label.bpm`), never the English text, which lives in the macro's default. **`make strings` after touching any UI string**; `make check-strings` fails when the catalog is stale. **Display names are never identifiers** — the registry key, the defaults value and a menu item's identifier stay separate from the localized label. The **`vibe-strings` skill** is the reference for the registry conventions, the extraction pipeline, `InfoPlist.xcstrings`, translation terminology, the pseudolocale audit and the localized App Store page; read it before editing `VibeStrings.h`, the catalogs or `scripts/extract-strings.sh`.

## Key patterns

- **No private APIs, ever.** This app ships in the Mac App Store. Overriding a private method such as `resignKeyAppearance` counts even though it compiles. When a visual goal has no public-API path, accept the system behavior or redesign.
- **Deployment targets are macOS 13.0 and iOS 26.0.** `CLANG_WARN_UNGUARDED_AVAILABILITY: YES_AGGRESSIVE` is on, so anything newer needs an `@available` guard — never `#if` or an OS-version check — so `grep -rn '@available(macOS' Vibe` is the complete inventory of version-specific code.
- **Singletons**: `AppSettings`, `AppStats`, `AudioDeviceManager` (macOS), `FolderAccessManager` (macOS), `FolderArtResolver`, `Formatters`.
- **File hashing**: `NSURL+Hash.cacheKey` is the cache key for metadata and waveform data — `<size>-<mtime_us>-<sha1(resolved path)>`, from attributes alone. It resolves symlinks first and returns nil rather than a degenerate key when the stat fails. Hashing no content keeps it cheap but misses a rewrite or a move.
- **ObjC++ (.mm) only where C++ is genuinely needed**: the TagLib integration, the waveform data structures and the renderers. Keep C++ types out of headers that plain ObjC files import.
- **Comments only when required, and terse.** A comment states what the code cannot show: a trap, an ordering or threading constraint, a contract, a non-obvious why. Never narrate the next line, and never log a change — "renamed from", "added in" and how something was verified belong in commits. **Naming the bug a design prevents is welcome**: it is the most concrete form a why takes. Mark hard-won traps with `TRAP:`.
- **A trap may be written twice, and the code comment is the authority.** The directory doc carries it so it is read while *planning*; the `TRAP:` beside the code so it is read while *changing* that line. **Changing a trap means changing both** — `grep -rn 'TRAP:' Vibe` reaches every copy.
- **Third-party sources** in `ThirdParty/` are other authors' code. Do not restyle them.

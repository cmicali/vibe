# Project organization: work brief

This brief is for an agent working in a local checkout of Vibe with Xcode. It reorganizes the source tree for human readers. It splits large files by concern, moves code to the directory that owns it, and fixes names that mislead. **No behavior changes.** Every item is a move, a split, a rename or a doc edit.

The audit behind this brief was taken at `19a2120` on `main`. Line numbers below are from that commit. They drift as you work, so re-map a file with `grep -n '^#pragma mark\|^- (\|^+ (\|^static\|^@implementation\|^@interface\|^typedef\|^struct' <file>` before you move anything out of it.

## Already done on main

These items from the audit landed in `39bad74`, `6366d2a` and `19a2120`. Do not redo them.

- The agent docs were reflowed. Only three doc lines are still over 1500 characters (`Vibe/iOS/AGENTS.md:106`, `.claude/skills/vibe-strings/SKILL.md:36` and `:53`). Item 10.2 finishes the job.
- `Vibe/iOS/Widget/AGENTS.md` and `VibeWidget/AGENTS.md` exist, and the root subsystem map names both.
- The 1.15 release log is gone. Its open findings are in `docs/bugs/open-issues.md`.
- `Search/FileSearchRules.h` gained `VibeBrowserRootLocationIndex`, with a test in `FileSearchRulesTests.m`. Item 8.6 must move it with the other root-row rules.

## Ground rules

1. **Read the root `AGENTS.md` first**, then the `AGENTS.md` of every directory you touch. Follow its writing rules, its vocabulary and its "shared checkout" rules.
2. **The owner has authorized new files and new types for this work.** Phase 0 amends the root `AGENTS.md` complexity budget to say so. Do that phase first, so the docs stop arguing against the rest.
3. **No behavior change.** Do not fix bugs you find on the way. List them in your final report instead.
4. **Work in a worktree.** `git worktree add .claude/worktrees/org -b org/phase-0 origin/main`. Use one branch per phase, each stacked on the one before. Use one commit per numbered item, so items can be cherry-picked or dropped. Run `git branch --show-current` before every commit. Stage by path. Never use `git commit -a`.
5. **No agent attribution** in commits, code, comments or docs. No `Co-Authored-By` trailer.
6. **Ask the owner before opening any pull request.** When asked, write it with the `vibe-pr` skill.
7. **Keep every basename unique.** Xcode's headermap resolves `#import "X.h"` by basename, so a duplicate name compiles against the wrong file.
8. **Moving files between directories is free in the app targets**, because `project.yml` lists whole directories. It is not free in `VibeTests` and `VibeAudioTests`, which list production sources one by one. Update those lists for every moved or new `.m`/`.mm`, and every search path that names a moved directory. Run `xcodegen generate` after every `project.yml` edit.
9. **Docs follow the code.** Every `AGENTS.md` that names a moved file, class or function is updated in the same commit. A `TRAP:` comment moves with its code, and its doc copy is updated too (`grep -rn 'TRAP:' Vibe`).
10. **Do not rename archived classes.** `AudioWaveform` and `AudioTrackMetadata` conform to `NSSecureCoding`, and users have them on disk. Do not change settings keys, stored identifiers, `STR_*` keys or menu identifiers.
11. **Leave `Vibe/ThirdParty/` untouched.** Do not move `Tests/BenchComponents/`, because `.claude/skills/vibe-perf/scripts/perf.py` hard-codes its path and copies it into old checkouts.
12. **No `#if DEBUG` in a shipping header** (`make check-vocabulary` enforces this). Debug-only declarations stay in `+Debug.h` categories under `Vibe/Debug/`.
13. **Drop an item if the split reads worse.** If a split makes the code harder to follow once it is written, revert it and say why in the report. That is a valid outcome.

## How to verify each phase

Run all of these before closing a phase. Each must pass.

```sh
make test                     # host-less unit tests
make test-audio               # render suite, needs ffmpeg for full coverage
make analyze CONFIG=Release   # both app targets, zero findings outside ThirdParty
make build CONFIG=Debug
make build CONFIG=Release
make build CONFIG=AppStore
make build-ios CONFIG=Debug
make check-layout check-vocabulary check-strings
make compile-commands         # then confirm clangd sees the new files
```

**Prove a move changed nothing.** Before a phase, record the symbols of the Debug macOS binary and the Debug iOS simulator binary. Record them again after the phase.

```sh
nm -j build/DerivedData/Build/Products/Debug/Vibe.app/Contents/MacOS/Vibe | sort -u > /tmp/sym-before.txt
# … do the phase, rebuild …
nm -j build/DerivedData/Build/Products/Debug/Vibe.app/Contents/MacOS/Vibe | sort -u > /tmp/sym-after.txt
diff /tmp/sym-before.txt /tmp/sym-after.txt
```

The diff may contain only symbols you renamed on purpose, and `static` helpers that became shared. Explain every other line. Do the same for the iOS app under `build/` (find its path with `find build -name VibeiOS -type f -path '*Debug-iphonesimulator*'`).

**Render-path code needs a performance check.** Phases 4 and 5 move real-time code (`VibeVoiceBusRender`, `VibeMasterBusRender`, the voice-bus decoder and the MPEG decode) across translation units. A `static` helper that was inlined can stop being inlined. Before and after, run `make bench-components` (`python3 .claude/skills/vibe-perf/scripts/perf.py compare main`). Any render, decode, seek or resample benchmark that moves by more than about 1% in retired instructions must be explained. Usually the fix is a `static inline` in the private header. The `vibe-perf` skill has the details.

**Threading-sensitive splits need TSan.** After Phase 4's voice-bus split, run `AudioVoiceBusTests` and the render suite under ThreadSanitizer, as `Tests/AGENTS.md` describes (`-enableThreadSanitizer YES -enableCodeCoverage NO`, separate derived data).

**Shell phases need a live check.** After Phases 6 and 7, use the `vibe-debug` skill on Debug builds. On macOS, launch the app, run `dump_state`, play a file, open every Settings pane, take a screenshot of each, and compare them with screenshots taken before the phase. On the iOS simulator, open the Files tab root, a folder, Recents, the Open URL sheet, Search and the Playlist tab, and compare screenshots the same way. Pixels must match, apart from timestamps and other live content.

## Reporting

At the end of each phase, report these things. The root `AGENTS.md` "Say what the change removes" rule asks for them.

- The net line count.
- The new files and the new types.
- What moved, from where to where.
- Items dropped, and why.
- Anything you noticed but did not fix.

At the end, give one table of every file over 700 lines, with its size before and after.

---

## Phase 0: policy

**0.1 Amend the complexity budget.** In the root `AGENTS.md`, rewrite the "zero new files and zero new types" paragraph. A new *concept* (a class, protocol, `*Rules.h` or directory for new behavior) is still argued for before it is written. Splitting an existing file by concern, or moving code to the directory that owns it, needs no argument. Write short, plain sentences.

**0.2 Add a doc line-length check.** Add a rule to `scripts/check-vocabulary.sh` that fails on any line over 1500 characters in an `AGENTS.md`, a `docs/**/*.md` file or a `.claude/skills/**/*.md` file. Break the three remaining long lines (listed above) so it passes. Put the threshold in one variable.

## Phase 1: mechanical moves

Each of these is a move with no untangling.

**1.1 The stall sampler leaves the player.** `Audio/AudioPlayer+Diagnostics.m` lines ~19–390 (`VibeCaptureStack`, `VibeDescribeStack`, `VibeFindThread`, `VibeLogStack`, `VibeSampleStack`, `VibeWatchQueueForStalls`, `VibeWatchMainThreadForStalls`, the scene-active flag) use no player state. Move them to `Vibe/Util/StallWatch.{h,m}`. Export the two watch functions and a `VibeStallWatchNoteSceneActive(BOOL)` in place of `+noteSceneActive:`. `iOS/PlaybackController.m` then imports `StallWatch.h`, not the player's diagnostics header. Keep the `VIBE_VERBOSE_LOGGING` guards exactly as they are.

**1.2 The error constructors join the error vocabulary.** Move `VibeAudioError` and `VibeAudioErrorForTrack` from `Audio/AudioPlayer.m` (~L37–62) to `Audio/AudioError.m`. Declare them in `AudioError.h`, or keep them in `AudioPlayerInternal.h` if nothing outside the player calls them.

**1.3 `PINCache+VibeAudioCache` moves to `Vibe/Util/Categories/`.** Only `Metadata/AudioTrackMetadataCache.m` and `Waveform/AudioWaveformCache.mm` use it. Update the `VibeTests` path.

**1.4 The menu-identifier registry moves to the menu.** Move `Mac/MainWindow/MenuValidationRules.h` to `Mac/Menu/`. Its importers are app-wide.

**1.5 The macOS `main.m` moves under the app.** Move the root `main.m` to `Vibe/Mac/App/main.m`. Drop `- path: main.m` from `project.yml` and fix the sentence in `Vibe/Mac/App/AGENTS.md`.

**1.6 Feature code leaves `Util/Mac/`.** Util's own rule is "no feature". Move `TrackCommands` to `Playlist/Mac/`, `NSDockTile+Util` to `Mac/App/`, and `Fonts` to `Common/Mac/Theme/`. Rename `Util/Categories/NSURL+AudioOpen` to `NSURL+Emptiness`, since it holds only `isEmptyOrDirectory`. Delete the unused `#import "AppSettings.h"` in `Util/Formatters.m`.

**1.7 `CloudFileAvailability` gets its own file.** It is the class in `Loading/CloudFileMaterializer.m` lines ~75–530, with its interface in `CloudFileMaterializer.h` ~L50–186. Move it to `Loading/CloudFileAvailability.{h,m}`. `CloudFileMaterializer.h` imports the new header if its API needs the type.

**1.8 TagLib leaves the metadata model.** In `Audio/Metadata/AudioTrackMetadata.mm`, move `VibeTagLibDebugListener`, `VibeRangedStream`, `VibeOpenTagStream` and `TagLibAudioFile` (~L48–272), `fileTypeForTagLibFile`, `albumArtDataFromTagLibFile`, `VibeTagLibArtExtractor` and the `getAlbumArt*` readers (~L682–883) to `Audio/Metadata/TagLibAudioFile.{h,mm}`. The header is C++, so only `.mm` files import it. Move `VibeEncodedArtData` (~L460) to `Common/PlatformImage.{h,m}` as `VibeEncodedImageData`, beside `VibeDecodedImageWithData`. Move the C functions that sit inside `@implementation` outside it. TagLib stays out of `VibeTests`.

**1.9 The browser header stops being a utility header.** `iOS/BrowserViewController.h` ~L86–107 declares app-wide helpers that 9 files import the browser for. Move `VibePresentAlert` and `VibeTopmostPresenter` to `Util/iOS/UIViewController+Alert.{h,m}` as category methods. Move `VibeMenuAction`, `VibeApplyFileNameStyle`, `VibeNotDownloadedMark`, `VibeApplyRowContent`, `VibeRowIsInViewport`, `VibeFileTileImage`, `VibeApplyFileIcon` and `kFileTileSide` to `iOS/FileRow.{h,m}`. A helper whose first argument is a UIKit object becomes a category on that class, following the Vocabulary rule. Then remove each `#import "BrowserViewController.h"` that is no longer needed.

**1.10 The replace prompt moves to the model.** `+confirmReplacingPlaylistOf:…` and `+openLinkString:…` (`BrowserViewController.m` ~L957–1017) are called by Search and Favorites. Move them to a `PlaybackController+ReplacePrompt.{h,m}` category as instance methods. Search and Favorites then stop importing the browser.

**1.11 Second classes move to their own files.**
- `RecentsViewController` (`BrowserViewController.m` ~L63–69 and ~L2077–2306) moves to `iOS/RecentsViewController.{h,m}`.
- `LibraryTrackCell` (`LibraryViewController.m`) moves to its own file.
- `SettingsSidebarController` and its cell (`Mac/Settings/SettingsWindowController.m` ~L148–404) move to `Mac/Settings/SettingsSidebarController.{h,m}`.
- `LinkClient` (`Loading/Net/LinkStore.m` ~L79–307, and its part of `LinkStore.h`) moves to `Loading/Net/LinkClient.{h,m}`.
- `EmbeddedThumbnailKey`, its node and its LRU cache (`Audio/Metadata/AudioTrackArtwork.m` ~L61–235) move to `Audio/Metadata/EmbeddedThumbnailCache.{h,m}`.
- The token classes in `Loading/AudioFileMaterializationCoordinator.m` (~L208–364) move to `Loading/AudioFileMaterializationTokens.{h,m}`.

**1.12 `VibeStrings.h` sections go back under their headings.** Move "macOS settings clarity" (~L772–788) under "Settings window". Move the iOS player FX and accessibility strings (~L692–695) under "iOS". Change no key and no default text. `make check-strings` must still pass with no catalog change.

## Phase 2: the debug channel

**2.1 Give `Vibe/Debug/` subdirectories that match its doc.** The sections of `Debug/AGENTS.md` are the transport, the verbs, the oracles and the simulators. Create:
- `Channel/`: `DebugChannel`, `DebugCommandDispatch`, `DebugWireFormat`.
- `Verbs/`: `DebugCommonVerbs`, `DebugPlayerSurface.h`.
- `Oracles/`: `DebugConsistency`, `AudioLoadTiming`, `VibeWorkTally`.
- `Simulators/`: `VibeFakeCloud`, `VibeFakeHTTP`, `VibeManualRenderPump`.
- `Seams/`: every `+Debug.h` and `+Debug.m`.

Rename `Mac/Introspection/` to `Mac/Seams/`. Move `Mac/AudioFileConverter+Debug.{h,m}` into it. Give iOS an `iOS/Seams/` for its `+Debug` pairs. Update the 9 explicit test-target paths in `project.yml` and the `$(SRCROOT)/Vibe/Debug` search path in `VibeTests`. Also update the message in `scripts/check-vocabulary.sh` that names `Mac/Introspection/`, and the `Vibe/Debug/` paths in docs and skills (`grep -rn 'Vibe/Debug/' .claude docs Vibe --include=*.md`).

**2.2 Split the verb tables by topic.** `VibeDebugUnknownCommandReply` already takes a list of tables. Give each topic file a function `NSArray *VibeDebug<Topic>Verbs(void)`, and have the common table concatenate them. Each verb's helpers move with it.
- `Verbs/DebugCommonVerbs.m` (1248 lines, one 48-verb array) splits four ways:
  - It keeps state and transport.
  - `DebugStallVerbs.m` takes the `block_*` verbs, `hang_open` and `set_slow_volume`, with their `NSCondition` state.
  - `DebugLoadingVerbs.m` takes the cloud, row-loading, fake-cloud, dataless, `open_url`, link and fake-HTTP verbs.
  - `DebugAudioVerbs.m` takes the equalizer, audio-path, decoder, resampler-cost, cache, timing and waveform verbs.
- `Mac/DebugCommandTable.m` (849 lines) moves its theme verbs to `Mac/DebugThemeVerbs.m`, its output-device verbs to `Mac/DebugOutputVerbs.m`, its convert and undo verbs to `Mac/DebugConvertVerbs.m`, and its window-width and resize verbs to `Mac/DebugWindowVerbs.m`.
- `Mac/DebugInput.m` keeps raw keys, mouse and gestures. Its synthetic file drags and reorder drags (~L506–789) move to `Mac/DebugSyntheticDrags.m`. The doc's "Desktop input boundary" section already treats them as different kinds of input.
- `iOS/DebugCommands.m` moves its Dropbox and fake-Dropbox verbs (~L264–378) next to `VibeFakeDropbox`.

The unknown-command reply must list exactly the same verbs before and after. Diff its output on both platforms.

**2.3 Rename the dispatcher files.** `Mac/DebugUtil.{h,m}` holds the mac's debug entry points, not utilities. Rename it `Mac/DebugMacEntry.{h,m}`, or a clearer name you find. Give the iOS table and dispatcher parallel names, with distinct basenames.

**2.4 Split the fake HTTP server.** Move `VibeFakeHTTPProtocol` and `VibeFakeHTTPAnswer` out of `Simulators/VibeFakeHTTP.m` into `Simulators/VibeFakeHTTPProtocol.{h,m}`. They are the engine that the tests' `HTTPStub` subclasses. Break `-answerForRequest:` (~210 lines) into lookup, fault and range steps.

## Phase 3: tests and the test targets

**3.1 Split `Tests/AudioPlayerRenderTests.m` (6606 lines, 8 classes).**
- Create `Tests/AudioRender/`.
- The base class and its helpers go to `AudioPlayerRenderTestCase.{h,m}`. Put the PCM compare, RMS and tone helpers in its `.m`, or in a small `AudioRenderCompare.h`.
- Each subclass gets its own file.
- Split the Transport subclass along its existing marks: crossfade, cue rows, read-ahead and estimated length.
- In `project.yml`, `VibeAudioTests` takes `Tests/AudioRender` as a directory, and `VibeTests` excludes `AudioRender/**`.
- Update `Tests/AGENTS.md`.
- `make test-audio` must run the same number of tests before and after. Compare the counts.

**3.2 Mirror the source tree in `Tests/`.**
- Move test files into `Tests/Audio/` (with `Metadata/`, `Waveform/`, `Levels/` and `FX/` below it), `Tests/Loading/` (with `Net/` below it), `Tests/Playlist/`, `Tests/WaveformUI/`, `Tests/Common/`, `Tests/Util/`, `Tests/Mac/` and `Tests/iOS/`.
- Shared helpers go to `Tests/Support/`: `AudioFixtures.h`, `HTTPStub`, `LinkStoreTestCase`, `TestFilesystemGuard`, `VibeReadAheadScript`.
- Add a short "Helpers" list at the top of `Tests/AGENTS.md`.
- `iOSDriver/` and `BenchComponents/` stay where they are.
- `make test` must run the same number of tests before and after.

**3.3 Split the other large test files along their existing marks.**
- `AudioTrackMetadataLoaderTests.m`: move its ~400 lines of fakes to `Support/MetadataLoaderTestFakes.{h,m}`. Add `#pragma mark` groups: stage one, priority, shared files, retries, foreground yield, admission and cancellation. Split it into files if the groups are large.
- `AudioFileMaterializationCoordinatorTests.m`: move its fake controller to `Support/`. Add marks or split it in two.
- `DropboxMirrorTests.m`: split it into Mirror, Fetch and Streaming. Check whether `HTTPStub` can replace its own `DropboxStubProtocol` (~L31–243). Replace it only if the tests stay the same.
- `AppThemeTests.m`: split out `AppThemeNameTests` and `AppThemeStoreTests`.
- `AudioFileHandleStreamingTests.m`: split out `AudioFileHandleReadAheadTests`.
- `AudioVoiceBusTests.m`: split out `AudioVoiceBusPoolTests` (the "Starvation, kills and the pool" mark).
- `OutputFormatRulesTests.m`: split out `AudioDeviceManagerTests`.

**3.4 Remove the duplicated test source lists.** `VibeTests` and `VibeAudioTests` copy about 40 source entries and their compiler-flag anchors. Move the shared entries into an XcodeGen `targetTemplates:` entry. Keep the lists curated. Do not switch to whole directories.

## Phase 4: the audio engine

Run the performance and TSan checks from the top of this brief.

**4.1 Split `Audio/AudioVoiceBus.m` (2018 lines) three ways.**
- Grow `AudioVoiceBusInternal.h` into the private header. It takes:
  - the constants enum, `VibeSuccessorState`, `VibeStreamState`, `kUnset` and `VibeRampWord`
  - the three structs and the `VibeSlot*` inlines
  - `VibeStampRead`
  - the `AudioVoiceRecord` interface
  - the ivar block as a class extension
- Then split:
  - `AudioVoiceBusRender.m`: plain C, the real-time render and its mix helpers, ~260 lines.
  - `AudioVoiceBus+Decoder.m`: mix-map helpers, prepare, conversion, slot recycling, fills, the converter feed, chunk decode, stream end and reopen.
  - `AudioVoiceBus.m`: the queue side.
- Rename the seam category in `AudioVoiceBusInternal.h` from `(Rendering)` to `(Testing)`, since it declares pool and decoder hooks.

**4.2 Split bit-perfect output out of `Audio/Mac/Devices/AudioPlayer+Devices.m` (1490 lines).**
- Lines ~778–1368 and the public setter (~1436–1476) move to `AudioPlayer+BitPerfect.{h,m}` in the same directory.
- Move the queue-side `(DevicesInternal)` methods out of `AudioPlayer+Devices.h` into `AudioPlayer+DevicesInternal.h`. Only `AudioPlayerInternal.h` imports it.
- Move the ~60 lines of mac device ivars in `AudioPlayerInternal.h` (~L168–230) into a class extension in that Mac-only header.
- Fix the pragmas that say "declared in AudioPlayer.h".

**4.3 The master bus becomes its own unit.** Move the master-bus struct, `VibeMasterBusRender` and `VibeMasterBusCreate`/`SetVolume`/`RenderInside`/`Free` out of `Audio/AudioPlayer+Pipeline.m` into `Audio/AudioMasterBus.{h,m}`. A private header exposes the struct to the pipeline category.

**4.4 Split the `AudioFX` header by audience.** Move the pipeline-only API in `Audio/FX/AudioFX.h` (`setConnected:format:…`, `markDead`, `chain`, `unitRenders`, `VibeFXChainRender`) to `AudioFX+Pipeline.h`. Leave `AudioFX.m` whole.

**4.5 The read-ahead moves to Loading.** This finishes the move in `07a807f`.
- Move the network-mount read-ahead out of `Audio/AudioFileHandle.m` into `Loading/NetworkReadAhead.{h,m}`. That covers:
  - the constants, the orphan counter and the debug hooks (~L76–107)
  - `VibeReadsAhead`, the orphan cap, `VibeReadAheadOpen`, `VibeReadAheadPread` and `VibeReadAheadRun` (~L249–499)
  - the body of `-readAheadOnMount:`
- The handle calls a small C API: whether to read ahead, wait for room, start, and the handle is gone.
- `AudioFileHandle+Debug.h` keeps its methods as forwarders.
- Update the file table in `Audio/AGENTS.md` and `Loading/AGENTS.md`, and the TRAP copies.

**4.6 Split the MPEG decode out of `AudioFileHandle.m`.** Do this last in the phase. It needs untangling.
- Move the dr_mp3 constants, `VibeUncountedMPEGPackets`, the open/settle/count/exact-length path and `readMPEG`/`decodeNextMPEGPacket` to `AudioFileHandle+MPEG.m`.
- Create `AudioFileHandleInternal.h` with a class extension carrying the `_mpeg*` ivars.
- Seek and the length getters also read those ivars, so check every reader.

**4.7 Small engine items.**
- Join the HAL event log, now split across `CoreAudioUtil.m` (~L673–745) and `AudioDeviceManager.m` (~L316–428), into `Audio/Mac/Devices/AudioDeviceEventLog.{h,m}`.
- Move the hog methods in `CoreAudioUtil.m` up beside `readHogOwner`.
- Rename `AudioResampler.{h,mm}` to match the `VibeConverter*` type it declares, or rename the type to `VibeResampler*`. Pick one and use it everywhere.

## Phase 5: loading, metadata and waveform

**5.1 Break up `Util/NSURLUtil.m` (972 lines).**
- Path identity (`VibeAliasFreePath`, `VibeComparablePath`) moves to `Util/FilePaths.{h,m}`.
- Remote-placeholder recognition and dataless detection move to `Loading/PlaceholderFiles.{h,m}`. Fold them into one registry, with one lock, together with `sRemoteBackends` in `CloudFileMaterializer.m`. Today `setRemoteRoot:` pushes prefixes into `NSURLUtil setRemotePlaceholderRoots:`, and nothing else calls that.
- The folder walk (~L292–972) moves to `Playlist/FolderWalk.{h,m}`, with `NSURLUtilInternal.h` renamed `FolderWalkInternal.h`. Move `Util/AGENTS.md`'s walk section to `Playlist/AGENTS.md`, and move `FolderOpenSort.h` beside the walk.
- 39 files import `NSURLUtil.h`. Update each one to the header it now needs, and delete `NSURLUtil` if nothing is left in it.

**5.2 Split `Loading/AudioFileMaterializationCoordinator.m` (1732 lines).**
- The private model classes (HandleRun, Waiter, ProbeActivity, Claim) and the ivar block go into a class extension in `AudioFileMaterializationCoordinatorInternal.h`.
- Stage-2 handle runs (~L1440–1693) move to `AudioFileMaterializationCoordinator+HandleOpen.m`.
- Stage 1 stays as one file. It is one state machine.

**5.3 Dropbox moves under Loading.** `Vibe/iOS/Dropbox/` has no UI. `DropboxClient` subclasses `HTTPTransferClient`, `DropboxMirror` subclasses `RemotePlaceholderStore`, and both compile into the macOS tests. Move the directory to `Vibe/Loading/iOS/Dropbox/`, which the mac target already excludes. Move the Keychain and app-key constants from `DropboxMirror.m` to `DropboxClient.m`.

**5.4 Group `Loading/`.** Create `Loading/Claim/` (coordinator, tokens, scheduler, admission rules, configuration, open rules, timeout math) and `Loading/Transfer/` (materializer, availability, registry, progress monitor, adapters). Leave `Net/` as it is. Move the "Drops" section of `Net/LinkRules.h` (~L411–500: drop, paste and webloc routing) to `Net/LinkDropRules.h`, and split its tests to match.

**5.5 Split `Audio/Metadata/AudioTrackMetadataLoader.m` (1581 lines).**
- First break `completeMaterializationForEntry:` (~195 lines) into slot settlement, yield triage and parse scheduling.
- Move `MetadataScanEntry` and `MetadataPriorityMark` to `MetadataScanEntry.{h,m}`.
- Move the ivars to a class extension in the internal header.
- Create `+Materialization.m` (the lane, plus the priority-mark helpers it uses) and `+Parse.m` (cache read, parse, install, settle, publish).
- The display-art sidecar helpers move with the parse.
- `Metadata/AGENTS.md` forbids a second coordinator. Categories add no type, so they satisfy that rule.

**5.6 Split `WaveformUI/iOS/WaveformScrubberView.mm` (1425 lines)** the way the mac view already is.
- Create `WaveformScrubberViewInternal.h` with the ivar block.
- `+Bitmap.mm` takes the bake store, `showWaveform:animated:`, the throttle, the bake, segments, the install and the reveal.
- `+Loading.mm` takes the loading indicator.
- `+Gestures.mm` takes the touch scrub and the pinch.
- `cancelInteraction` and `resetWaveformContentState` stay in the core.

**5.7 Split `Audio/Mac/Convert/AudioFileConverter.m`.** Move undo, redo, trash, restore and verify (~L392–680) to `AudioFileConverter+Disposal.m`, with their ivars in `AudioFileConverterInternal.h`.

**5.8 Waveform helpers and folders.**
- Move the numeric geometry in `WaveformUI/Renderers/AudioWaveformRenderer.h` to `WaveformBarMath.h` (`VibeBlockIndexForX`, `VibeBarVScale`, `VibeBarBaseline`, `VibeBarSeekHitBand`, `VibePlayheadLineRect`, `VibeSnappedColumnRect`).
- Move the Foundation-only level helpers to the existing `WaveformLevelMath.h`.
- Update `Renderers/AGENTS.md`, which calls that header their one home.
- Create `Audio/Metadata/Artwork/` for `AudioTrackArtwork`, `ArtworkLoadRegistry`, `EmbeddedThumbnailCache` and `FolderArt/`.

**5.9 Waveform names.** `AudioWaveform*` is the data layer. The UI layer becomes `Waveform*`:
- `AudioWaveformRenderer` → `WaveformRenderer`
- `BasicAudioWaveformRenderer` → `BasicWaveformRenderer`
- `DetailedAudioWaveformRenderer` → `DetailedWaveformRenderer`
- `OversamplingDetailedAudioWaveformRenderer` → `OversamplingDetailedWaveformRenderer`
- `AudioWaveformView` → `WaveformView`, with its categories

Do not rename the data classes. `AudioWaveform` is archived. Also rename `AudioTrackMetadataLoaderInternal.h` and `AudioTrackArtworkInternal.h` to plain `.h`, since each is that class's only header.

## Phase 6: the macOS shell

Do the live check from the top of this brief.

**6.1 Settings names match the panes.**
- Rename `Mac/Settings/Appearance/` to `Mac/Settings/Themes/`, and `SettingsAppearanceViewController*` to `SettingsThemesViewController*`. It is the Themes pane.
- Split `SettingsGeneralViewController.m` (one class showing three panes through `SettingsGeneralPage`) into three controllers: `SettingsGeneralViewController`, `SettingsAudioOutputViewController` and `SettingsAppearanceViewController`. Then delete the enum.
- Update `SettingsWindowController`, `Debug/Mac/DebugSettingsUI.m`, `Tests/BenchComponents/VibeBenchComponentsSettings.mm` and `AppThemeTests.m`.

**6.2 Break up the theme editor.** In the theme editor's `+Editor.m` (1260 lines), split `buildEditorPage` (~390 lines) into one builder per section: Name, App icon, Window, Player, Transport, Info, Volume, Waveform, Playlist. Then move the state and actions half (~L735 to the end) to `+EditorActions.m`.

**6.3 The theme store leaves `AppSettings+Mac`.** Move `Common/Mac/AppSettings+Mac.m` ~L188–758 (theme migrations, store, history, sweep, rename) and `setCurrentThemeImageForKey` to `Common/Mac/Theme/AppSettings+Themes.{h,m}`. Move the theme half of `AppSettings+Mac.h` with it. The state is already in `AppSettingsInternal.h`. Do not change any defaults key.

**6.4 Split `Common/Mac/Theme/AppTheme.m` (1601 lines).** Create `AppTheme+Images.m` (the file store and image cache), `AppTheme+JSON.m` and `AppTheme+Dice.m`. Declare the schema helpers they share in the existing `AppThemeInternal.h`. The schema tables, resolution, built-ins and record stay.

**6.5 Regroup `MainPlayerController`.**
- Create a `+Playlist` category: close, save and write, last playlist, removal, reinsert, move and undo.
- Move shuffle, repeat, `successorPrefetchTrack`, `pushTransportModesToPlaylist`, `applyEndOfTrackAction`, `applyPitchRange`, `updateRateDependentUI`, the pitch-panel delegate and `volumeChanged:` from the "Actions" section to `+Transport`.
- Move the folder-art, grant and thumbnail notification handlers to `+Delivery`.
- Move the waveform seek out of `+Delivery` to `+Transport`, and the waveform theme resolution to `+Window`.
- Move `refreshWaveformTheme` from `+Menus` to `+Window`.

**6.6 The session store leaves shared code.** The last-playlist session store in `Playlist/PlaylistFile.m` (~L15–52, and `kVibeLastPlaylistCurrentIndexKey`) is mac-only, and only `MainPlayerController` calls it. Move it to the new `+Playlist` category, and move its tests with it. Then split `PlaylistFile` into `PlaylistFile+CUE.m` (CUE and the embedded FLAC sheet) and the M3U read and write.

**6.7 Extract the volume control.** Move the label, slider, percentage, their layout, the percent rendering and the color resolution out of `Mac/MainWindow/MainPlayerContentView.m` (~L423–596 and ~L821–845) into `Mac/MainWindow/VolumeControlView.{h,m}`. `setControlsShown:animated:` still decides every alpha.

**6.8 Name the layout doc after what it covers.** Rename `Mac/MainWindow/APPEARANCE.md` to `LAYOUT.md`, which is what its own title says. Point `MainWindowLayout.h` at the layout block in `MainPlayerContentView.m`.

**6.9 Slim the app delegate.** Move the Open URL panel (~L633–785, its ivars, and its `NSWindowDelegate` and `NSTextFieldDelegate` roles) out of `Mac/App/AppDelegate.m` into `Mac/App/OpenLinkWindowController.{h,m}`. Move Sparkle (~L210–260) to `AppDelegate+Updates.m`.

**6.10 Small mac moves.**
- `VibeDetentSlider` moves from `SettingsFormViews.m` to `Mac/Controls/`.
- `Audio/Mac/Convert/` moves to `Vibe/Mac/Convert/` as an app-shell piece. It is mostly file management and menu validation. This needs a new mac source entry in `project.yml` and updated test paths. Skip it if `make check-layout` objects.

## Phase 7: the iOS shell

Do the live check from the top of this brief.

**7.1 Give the Files tab its own directory.** Create `Vibe/iOS/Files/` holding the browser, Recents, the Open URL sheet and `FileRow`. Move the browser section of `Vibe/iOS/AGENTS.md` into a new `Vibe/iOS/Files/AGENTS.md`, and break its line 106 if Phase 0 did not. Rename `LibraryViewController` and `LibraryTrackCell` to `PlaylistViewController` and `PlaylistTrackCell`. The tab, its strings and its doc already call it the Playlist tab.

**7.2 Extract the Open URL sheet.** Move the sheet that `BrowserViewController.m` builds (~L1019–1236, with `_linkSheet`, `_linkField`, `_linkOpenItem`, `_linkSpinner`, and the text-view and presentation delegate roles) to `Files/OpenURLSheetController.{h,m}`. It takes an open block and a cancel block and has a `resolving` property. The paste row shares `_cancelLinkResolve` with the sheet, so pass that flag explicitly.

**7.3 Split the root screen from the folder screen.** `BrowserViewController` serves both through about 20 `isRoot` branches. Split it into `FilesRootViewController` and `FolderViewController`.
- **Root:** the Locations and action rows, source selection and Dropbox sign-in, the add-location menu, the pickers, the paste row, `showDirectory:highlighting:` and the debug link state.
- **Folder:** art, listing, filter, bar, select and sort, the subfolder walk, lift and add-selected, highlight, the equalizer, item cells, swipe actions and the item context menu.
- Folder screens read `stackArtCache` and `equalizerSurfaceVisible` from the root through `navigationController.viewControllers.firstObject`. Pass them in explicitly instead.
- `showDirectory:` writes `_highlightURL` and `_holdsScope` on a new browser. Make those init parameters.
- Keep the Dropbox-linked flag that `6366d2a` added. The root reads it at its last reload, and every Locations row reads it. Keep `VibeBrowserRootLocationIndex` as the one map from a row to its store index.
- This item needs untangling. Do it last in the phase. Drop it if the result is not clearly easier to follow.

**7.4 Add an `+Opening` category.** Move the open and add roads, the opening-row spinner state, the restore and launch settle, and the `FolderSessionDelegate` conformance (`iOS/PlaybackController.m` ~L706–1050) to `PlaybackController+Opening.m`. Declare `observerSnapshot` and `notifyHasNothingToRestore` in `PlaybackControllerInternal.h`.

**7.5 Break up the folder open.** `-openURLsOnWorkQueue:…` in `iOS/FolderSession.m` is ~330 lines with 10 parameters. Split it into one method per phase: resolve rows, adopt or release holds, mint and persist bookmarks, and record recents. Pass a small result between them. Fix the header comment that says it owns "the picker". Change its UIKit import to Foundation if nothing needs UIKit. Move recents to a `RecentsStore` beside `FavoritesStore`, and remove the three passthroughs in `PlaybackController`.

**7.6 Rules and stores the Files tab owns.**
- Move the root-row rules out of `Search/FileSearchRules.h` into `Files/BrowserRules.h`: `VibeBrowserRootSection`, `VibeBrowserRootRow`, `VibeBrowserRootRows` and `VibeBrowserRootLocationIndex`, with the Recents URL rule.
- Move `VibeFolderSessionPersistsBase` to `FolderSessionRules.h`.
- Split `FileSearchRulesTests.m` to match.
- Rename `SearchFolderStore` to `LocationStore` and move it to `Files/`. It is the Locations store and the app's only folder-naming function. Fix the doc that calls it "search scope and nothing else".

**7.7 Smaller iOS items.**
- Move the added-row flight in `RootViewController.m` to `RootViewController+AddedRows.m`.
- Give the `PlaybackObserver` methods their own `#pragma mark`.
- Move the CUE-folder grant prompt next to the Files pickers.
- Extract the Dropbox search state in `Search/SearchViewController.m` (~L350–545 and its 8 ivars) into a `DropboxSearch` model beside `FileSearchIndex`.
- Move `TrackPageCell.m`'s three helper view classes to `Player/TrackPageViews.{h,m}`.

## Phase 8: debug code out of shipping files

There are 115 `#if DEBUG` blocks in 31 shipping `.m`/`.mm` files. Where the class already has an `*Internal.h` that exposes the state, move whole debug methods into `Vibe/Debug/Seams/<Class>+Debug.m`, wrapped whole in `#if DEBUG`. `Seams/AudioFileMaterializationCoordinator+Debug.m` is the existing pattern. Keep small inline hooks inside hot paths, such as a counter or a hold in the render or decode loop, because they are the seams themselves.

Start with these files:
- `Loading/DownloadProgressMonitor.m` (35% debug)
- `Audio/Levels/AudioLevelPublisher.m` (23% debug)
- The `AudioPlayer (Debug)` implementation, now spread across `AudioPlayer.m` (~L1607–1783), `AudioPlayer+Pipeline.m` and `AudioPlayer+State.m`. Gather it into one `Seams/AudioPlayer+Debug.m`.
- `Loading/CloudFileMaterializer.m`'s fake-transfer hooks
- `Util/NSURLUtil.m`'s (or its successor's) dataless diagnostics
- `AudioTrackMetadataLoader.m` (~L1088–1176) and `AudioWaveformCache.mm` (~L600–676)

The `_debugBuffering*` ivars may have to become visible to the debug file. Do not add `#if DEBUG` to a shipping header. Declare them unconditionally in the `*Internal.h` with a comment, or reach them through a debug-only accessor. Report the count of blocks before and after.

## Phase 9: tooling and docs

**9.1 Write `docs/architecture.md` for human readers.** It needs:
- A directory tree.
- One paragraph per subsystem.
- The path a file takes from open to sound: open funnel, Loading, `AudioFileHandle`, voice bus, master bus, output unit.
- Where to look for what.

Link it from `README.md` and `CONTRIBUTING.md`. Have the root `AGENTS.md` subsystem map point to it rather than repeat it. Add `docs/README.md` as an index of `docs/`, listing `future/` and `not-doing/`. State whether `docs/file-loading-spec.md` or `Loading/AGENTS.md` is the authority where they overlap.

**9.2 Move the scripts CI runs out of the agent skills.**
- `make test-audio`, `make test-bit-perfect` and `build/verify-bit-perfect` call `.claude/skills/vibe-debug/scripts/generate-test-audio.sh` and `verify-bit-perfect.swift`. Move both to `scripts/test/`, and have the skill point there.
- There are two different `install-ios.sh` scripts, one in `scripts/` and one in the vibe-debug skill. Rename the skill's to `sim-install.sh`, and update its callers.

**9.3 Group `scripts/` (36 entries).**
- `build/`: build, build-lock, clean, run, install-ios, reset-state, analyze, generate-git-info.
- `checks/`: check-layout, check-vocabulary, check-translations, test-summary.
- `strings/`: extract-strings, catalog-languages.
- `release/`: release, github-release, brew-set-version.
- `appstore/`: release-appstore, the asc libraries, asc-upload, the appstore scripts, compose-app-store-overlay.
- `web/`: deploy-web and the web scripts.
- `analysis/`: validate-key, validate-tempo, varispeed-quality.
- `generate-readme-screenshots.sh` joins `screenshots/`.
- `bench/` stays.

Update every reference: the Makefile, `project.yml` (`generate-git-info.sh`), `.github/workflows/build.yml`, each script's own `source` and `dirname` paths, the skills and `docs/`. Finish with `grep -rn 'scripts/' --include='*' .` and check every hit.

**9.4 Small tooling items.**
- Add `make help`, printing each target's comment.
- Move the README screenshots at the top of `Assets/` into `Assets/readme/`, and update `README.md` and `generate-readme-screenshots.sh`.
- Open each nested `AGENTS.md` that lacks one with a two-line "This directory holds …" summary.

## Leave these alone

These files are large but read as one thing. Do not split them:
- `Audio/AudioPlayer.m` reads as one transport story. Its doc argues against splitting out buffering.
- `Loading/Net/HTTPTransferClient.m`
- `Audio/Metadata/FolderArt/FolderArtResolver.m`
- `iOS/Player/TrackPageCell.m`'s layout code
- `Playlist/Mac/PlaylistController.m`
- `Debug/Mac/DebugSettingsUI.m`
- `Audio/FX/AudioFX.m`'s implementation
- `Audio/Analysis/AudioBPMAnalyzer.mm`

`VibeStrings.h` stays one file, because it is one registry by design.

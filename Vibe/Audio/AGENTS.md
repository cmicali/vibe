# Audio

Vibe's audio features beside the engine, and how Vibe hosts the engine. **The engine is vibe-libs' `audio/Player`**: `AudioPlayer` and its categories, the voice bus, the master bus, the output unit, the error vocabulary, the mac's device and bit-perfect categories, and the iOS route recovery. Its `AGENTS.md` is the authority for the transport, the voice bus, threading, crossfades, prefetch and gapless, cue windows, settlement identity, opening a file, buffering and the stall, the live levels, the beta diagnostics, the device and bit-perfect rules, and the output recovery. Read it before changing anything the player does, and change it there.

The file handle it reads through, with the decoders it hosts, is vibe-libs' `audio/Decode`. The resampler, the varispeed, and the fades are `audio/DSP`. The words it shares with the rest of the audio code are `audio/AudioTypes`: `VibePlayableItem`, the item the player reads, `CueWindowMath.h`, `MusicalKey.h`, and `AudioFileFormat`. The file-open path beneath it is `files/FileLoading`. The output devices and the iOS audio session it plays through are `audio/OutputDevices`. The DJ FX and the meter are `audio/FX` and `audio/Meter`. Tempo and key detection is `audio/Analysis`. Each has its own `AGENTS.md`.

**The metadata pipeline is vibe-libs' `media/Metadata`**: the tag record and its CoreAudio fallback, the cache and its scan, embedded art and the row thumbnails, and folder art. Its `AGENTS.md` is the authority for them, and Metadata and artwork, below, is what Vibe does with them. The waveform's data is vibe-libs' `waveform/Waveform` and `waveform/WaveformLoading`, and how Vibe uses them is below. Rendering is `Vibe/WaveformUI/`. Convert to FLAC is the mac shell's (`Vibe/Mac/Convert/AGENTS.md`). `PINCache+VibeAudioCache`, the disk-cache policy the metadata and waveform caches share, is vibe-libs' `files/DiskCache`.

## How Vibe hosts the player

**There is one `AudioPlayer` per process.** The mac's `MainPlayerController` makes it (`+Construction`) and the iOS `PlaybackController` makes its own. Each is its delegate. Vibe's item is its playlist row, `AudioTrack` (`Playlist/AGENTS.md`), which the player only reads and hands back.

**Each app delegate pushes the player's error domain at launch**, before the player exists: `VibeAudioErrorSetDomain(NSBundle.mainBundle.bundleIdentifier)` in `applicationWillFinishLaunching:` on the mac and `application:didFinishLaunchingWithOptions:` on iOS. Both apps' identifier is `com.commonwealthrecordings.Vibe`, the string the player hardcoded before it moved. The host-less test targets push the XCTest tool's identifier from `TestFilesystemGuard`, at image load. A read before the push asserts in a debug build.

**The shells push Vibe's settings into the player.** Nothing in the player reads `AppSettings`.

- **Declick** (`AppSettings.declick`, Settings > Audio Output, default on) is `AudioPlayer.declick`, through `VibeSettingsLiveEffectDeclick` on the mac.
- **The crossfade** is Settings > Playback's slider, which shows the 10 ms declick minimum as off.
- **The volume** moves only with the mac's Volume control. iOS uses the system volume. The debug `--silent` is the volume stage's target of 0.
- **The pitch fader** is the mac's. Its varispeed is hosted only on macOS.
- **FX** follows the shared `audioFXEnabled`. The mac's five toggles and the iOS pad's levels are cleared synchronously when a bypass is submitted (`clearFXIntent`), and the mac redraws the cleared flags once through `updateFXIndicators`. The mac's keys write the toggles, and the iOS pad writes the numbers. Telling a tap from a hold is `TransportKeyMonitor`'s job. The pad's axes are vibe-libs' `AudioFXMath.h`.
- **Bit-perfect and exclusive output** are Settings > Audio's, through `setBitPerfectOutput:exclusiveOutput:enableFX:allowAnyDevice:`. Advanced's `allowBitPerfectOnAnyDevice` is `allowAnyDevice`. `AppSettings` remembers only enabled modes, per device UID, and answers `audioPlayer:outputModesForDeviceUID:bitPerfectOutput:exclusiveOutput:`. A carry of modes to the same model on another port is persisted on main through `AppSettings.carryOutputModesFromDeviceUID:toDeviceUID:`.

**What follows a track's end is the playlist's `trackEndSuccessor`** (root `AGENTS.md`). Each shell prefetches it on every track start. A writer of Pause at track end, repeat, or shuffle pushes them into the playlist and re-parks. Repeat One parks the playing row's own object, and Pause at track end parks nothing.

**File > Close is `stop`.** It fires no transport or track-end callback, and the shell owns the UI reset (root `AGENTS.md`).

**The shells show what the player decides.** `bufferingNoticeShown` puts Buffering… in place of the file info line (`Mac/MainWindow/AGENTS.md`). A hold edge moves the Now Playing clock, and a notice edge redraws the header. `VibeAudioErrorDeviceInUse` is shown on the parked track's info line. The bit-perfect report's edge redraws the header's lock and the Settings caption.

**The mac's device manager has three observers**: `AudioPlayer`, `OutputDevicesMenuController`, and `SettingsAudioOutputViewController`. The Output menu's checkmark follows `currentlyRequestedAudioDeviceId` (`Mac/Menu/AGENTS.md`). The delegate's `didChangeOutputDevice:` persists the choice. The player's side of Save Debug Info is `bitPerfectReportDictionary` and `outputDeviceDiagnosticSnapshot`, which `dump_state` reads too (`Mac/App/AGENTS.md`).

**Termination.** `AppDelegate` detaches the player's delegate on main. `applicationShouldTerminate:` calls `prepareForTermination`, so nothing restarts the output during `NSTerminateLater`.

**On iOS, `PlaybackController` is `AudioSessionController`'s delegate** (`iOS/AGENTS.md`). It maps each verdict onto the player's public API, calls `recoverOutput` after the remote Play command's resume (`PlaybackController+NowPlaying.m`), and releases the session on `audioPlayerOutputDidBecomeIdle:`. Its media-services reset completion publishes Stopped and re-parks the captured track.

## How Vibe uses the waveform loader

**The loader, the cache, and the observers are vibe-libs' `waveform/WaveformLoading`.** Its `AGENTS.md` is the authority for the decode pass, the bands, the store, cue windows, admission, detached decodes, streaming, and the deliveries. The summary and the cache entry are `waveform/Waveform`'s. Vibe's item is its playlist row, `AudioTrack`.

**Each shell owns one cache and installs its analysis provider.** The mac's `MainPlayerController` answers from the two analysis settings and the theme's style. The iOS `PlayerViewController` answers from `analyzeBPM` and the card's and widget's styles. A style asks for the bands through `WaveformRendererRegistry readsBandsForIdentifier:`. 3-Band and Spectrum are their only readers.

**Vibe's observers are the tempo and the key** (`Playlist/AudioAnalysisObservers.h`), identified as `bpm` and `key`. Key analysis is macOS-only (root `AGENTS.md`).

**An owner that comes to want more asks for its track again.** The mac asks when the style becomes 3-Band or Spectrum, or a detection switch turns on (`VibeSettingsLiveEffectWaveformStyle`, `VibeSettingsLiveEffectTrackAnalysis`). The iOS card asks when the card's or the widget's style does. Switching between 3-Band and Spectrum asks for nothing, since both read the same entry.

**Receivers match the delivered row's `sourceKey`**: `MainPlayerController+Delivery` and the iOS `PageWaveformCoordinator`. A tempo or key is stamped on every row sounding that window (`Playlist.stampTracksSounding:usingBlock:`). iOS reads only the tempo from the results, and forwards it to `PlaybackController.noteDetectedBPM:forTrack:`. The iOS pager reads its neighbors' entries only, through `cachedWaveformForTrack:completion:`. The iOS scrubber asks for the deep zoom blocks its last draw lacked (`WaveformUI/iOS/AGENTS.md`).

**The debug verbs drive the piece's two seams.** `file_cache`, `dump_waveform`, and `file_clear_cache` make a row for the file and pass it to the cache's seam. `set_waveform_decode_seconds` sets the decode pace. `dump_timing` and `clear_timing` read the loader's seam (`Debug/AGENTS.md`).

## Metadata and artwork

**Vibe's row, `AudioTrack`, is the metadata's holder** (`Playlist/AGENTS.md`). It adopts `AudioTrackMetadataHolder` and memoizes its cache key. Tags beat analysis on the row alone (root `AGENTS.md`).

**Each shell owns one `AudioTrackMetadataCache`**, rooted in the user's Caches directory (`init`): the mac's `MainPlayerController` (`+Construction`) and the iOS `PlaybackController`. The iOS Files tab keeps one more for its browser's art (`FilesRootViewController`). It sends only rows whose audio is not on the device to `loadCachedMetadata:` (`FolderViewController+Art.m`).

**The shells drive the scan, and the scan reads no setting.** The sweep waits until the picked track's open settles (`scheduleDeferredMetadataLoad`, root `AGENTS.md`). Every track start sends `loadMetadataNow:`. The one current-index funnel sends `setNeighborhoodTracks:` the playlist's `neighborhoodTracks`: the next two and the previous in play order. The removal funnel sends `abandonQueuedTrack:` for each removed row. File > Close and a playlist replacement send `cancelScan`. Each list redraws its visible rows on `AudioTrackMetadataThumbnailDidLoadNotification`.

**Folder art is the mac's.** `AppDelegate` installs the resolver's two providers at launch, from `AppSettings.useFolderArt` and `FolderAccessManager`'s grants. Beside them it installs the folder walk's handlers: the rank of each walked file, `VibeFolderArtCandidateRank` from `FolderArtRules.h`, and the listed and bulk-opened folders the resolver takes. A grant change sends `invalidateDirectoriesSettledWithoutGrant` (`MainPlayerController+Delivery.m`). The header coalesces `FolderArtDidResolveNotification` (`Mac/MainWindow/AGENTS.md`).

**TRAP: the resolver caches the setting.** Every writer of `useFolderArt` must request `VibeSettingsLiveEffectFolderArt`, whose mapping calls `folderArtSettingDidChange`. A direct defaults write is not observed (`Mac/Settings/AGENTS.md`, `Common/AGENTS.md`).

The debug channel's oracles and verbs read the cache's and the loader's seams, which sit beside their classes in vibe-libs (`Debug/AGENTS.md`).

## Live output levels

**The demand is the indicators', not play intent.** Each shell counts indicators declaring themselves consumers through `equalizerLevelsWanted:`. It enables levels only while the player's `outputAudioActive` and material visibility also hold (root `AGENTS.md`). The platform halves are `../iOS/AGENTS.md` and `../Playlist/Mac/AGENTS.md`. The meter and the player's side of it are vibe-libs' (`audio/Meter/AGENTS.md`, `audio/Player/AGENTS.md`).

The debug scripts launch with `--no-audio-hw --silent`, so the bars are live with the pump driving the render. `dump_equalizer` reports the flags, and `set_equalizer_mode balanced|activity|spectrum` picks the mode for the process. `--no-audio-hw` suits functional bar and counter checks, not audible-start-latency measurements. On the iOS simulator use `VIBE_AUDIBLE=1` for reactive validation.

## Error text

**`VibeAudioError*` descriptions are for logs and are never localized.** The one line a screen shows is `VibeStatusForPlayError` (`Common/StringRules.h`, tested), mapping `VibeAudioErrorCode` to a `STR_ERROR_*` string. Both screens render the same wording. **`AudioErrorRules.h` is which play failures a shell shows**: `VibePlayErrorIsBenign` and `VibePlayErrorMatchesCurrentURL`, a function of the error alone, so both screens agree (`AudioErrorRulesTests`). Both read the domain through `VibeAudioErrorDomain()`.

## Diagnostics

The player's beta lines (`Timeline:`, `Phase:`, `Callback:`, `Buffering:`, `Recovery:`, `Stall:`, `Signal:`) are vibe-libs' `audio/Player/AGENTS.md`'s. Save Debug Info retrieves them at `VIBE_VERBOSE_LOGGING=1` (`Mac/App/AGENTS.md`). `block_render`, `block_main_deep`, and `block_player` exercise the three stall paths. Keep each beta's dSYM, since a stall stack's frames are offsets into the executable. Under the pump, keep the playlist's equalizer visible and active while collecting `Signal:` lines, since the pump never holds the meter for a probe. `dump_state`, `dump_audio_path`, `dump_health`, and `check_consistency` read the player through its seam (`Debug/AGENTS.md`).

**The iOS recovery needs a real device.** On a device, check a buffering hold with the screen locked: the `Buffering:` line's held time against `dump_state.player` (`state` playing, `buffering` 1), and no `AudioOutputUnit: stop` or `AudioSession: deactivated` line. vibe-libs' `audio/Player/AGENTS.md` lists the edges to check.

## Tests

The player's tests are vibe-libs' `Tests/audio/Player`, and they run there. **The render suite is vibe-libs' `Tests/audio/Player/Render`**, which `VibeAudioTests` compiles from the submodule over the generated fixtures (`make test-audio`, `Tests/AGENTS.md`). Two test files stay here. `AudioPlayerRenderLinkTests` plays a link through Vibe's own `LinkStore`. `AudioQualityCorpusTests` runs only from the `vibe-audio-quality` skill. `Tests/Audio/AudioErrorRulesTests.m` covers `AudioErrorRules.h`. The waveform loader's and the observers' tests are vibe-libs' `Tests/waveform/WaveformLoading`. `Tests/Playlist/AudioAnalysisObserversTests.m` covers how Vibe reads its tempo and key from the results.

The metadata pipeline's tests are vibe-libs' `Tests/media/Metadata`, and they run there. `VibeAudioTests` also compiles its tag and fuzz tests from the submodule over the generated fixtures, so their Ogg cases run (`Tests/AGENTS.md`). Two test files stay here. `Tests/Playlist/AudioTrackTagTests.mm` checks the row over the real parse. `Tests/Playlist/FolderArtWalkTests.m` checks the walk's handoff to the resolver, as `AppDelegate` wires it.

# Architecture

This page is a map of the Vibe source for contributors. It shows where the code lives, what each part owns, and the path a file takes from open to sound. It names real classes and files, so you can jump straight to them.

The detail lives in the `AGENTS.md` files beside the code. Most directories with rules of their own have one. They are written for anyone changing that code, people and coding agents alike. Each section below names the one to read next. The root [`AGENTS.md`](../AGENTS.md) holds the project-wide rules: building, checks, the cross-directory guarantees, and the vocabulary.

## Two apps, one engine

Vibe is two apps. The `Vibe` target is the macOS app. The `VibeiOS` target is the iPhone and iPad app. Both are written in Objective-C, with Objective-C++ where C++ is needed. The Home Screen widget, `VibeWidget`, is written in Swift.

`Vibe.xcodeproj` is generated from `project.yml` by XcodeGen, and it is not checked in. Run `make project` after cloning, after pulling, and after any edit to `project.yml`.

**The directory is the platform boundary.** Every directory directly under `Vibe/` is compiled into both apps, except `Mac/`, `iOS/`, and `ThirdParty/`. Inside a shared directory, only a `Mac/` or `iOS/` subdirectory is platform-specific. A new file in a shared directory joins the iOS app automatically. It must not use AppKit unless the code is guarded by `TARGET_OS_OSX`. `make check-layout` enforces the rule.

Each app is a shell over the shared code. The shell owns the windows, the screens, and the gestures. The shared code owns playback, loading, the playlist model, metadata, and waveform drawing. The engine knows nothing about either shell. It reports back through a delegate.

## The tree

```
Vibe/
  Common/              settings, strings, document types
    Mac/               the macOS-only settings
      Theme/           AppTheme, the theme record, and the theme store
  Audio/               the playback engine: player, voice bus, master bus, output unit, file handle
    Metadata/          tags, the metadata cache, and the playlist scan
      Artwork/         embedded art and the shared row thumbnails
        FolderArt/     the cover image beside the files, for a file with no art (macOS)
    Waveform/          waveform data: the decode, the summary, and the disk cache
    Analysis/          tempo and key detection
    Mac/Devices/       CoreAudio output devices and bit-perfect output (macOS)
    iOS/               the audio session and output recovery (iOS)
  Loading/             the app's own transfers: HTTP, links, and Dropbox
    Claim/             which open runs, and when: the claim, admission, the handle ceiling
    Transfer/          the bytes: downloads, progress, streaming, the network read-ahead
    Net/               the app's own HTTP: transfers, placeholders, and Open URL's links
    iOS/Dropbox/       the Dropbox account and its local mirror (iOS)
  Playlist/            the playlist model, the folder walk, and CUE and M3U files
    Mac/               the playlist table and the last-playlist store (macOS)
  NowPlaying/          the system's Now Playing info and remote commands
  Controls/            controls both apps draw the same way: equalizer bars, loading indicator
  WaveformUI/          waveform drawing and the waveform theme
    Renderers/         the waveform styles and the morph engine
    Mac/               WaveformView (macOS)
    iOS/               WaveformScrubberView (iOS)
  Util/                Vibe's helpers with no feature
    Categories/        portable categories, such as NSString+CPPStrings
    Mac/ and iOS/      the AppKit and UIKit categories
  Debug/               the debug command channel, compiled into Debug builds only
    Channel/           the transport: command and reply files
    Verbs/             the commands both apps answer
    Oracles/           consistency checks and load timing
    Simulators/        stand-ins: a fake cloud, a fake HTTP host, the manual render pump
    Seams/             debug-only categories over shared classes
    Mac/ and iOS/      each app's command table, its own verbs, and its seams
  Mac/                 the macOS app shell
    App/               AppDelegate, the open funnel, sandbox grants, Open URL, updates
    MainWindow/        MainPlayerController and the player window
      Transport/       keys, skips, and FX toggles
      Convert/         the playlist side of Convert to FLAC
    Menu/              the menu bar
    Controls/          AppKit controls: buttons, the pitch fader, artwork views
    Settings/          the Settings window
      Themes/          the theme list and editor
    About/             the About window
    Convert/           the FLAC encoder and its file round trip
  iOS/                 the iOS app shell: PlaybackController, FolderSession, the tabs
    Files/             the Files tab: browser, Recents, and Locations
    Player/            the now-playing card
    Search/            Favorites and Search
    Settings/          the settings screens
    Widget/            the app's side of the Home Screen widget
  ThirdParty/          the prebuilt Sparkle framework; every other vendored library is in vibe-libs/third_party/
VibeWidget/            the widget extension, in Swift
vibe-libs/             the shared toolbox, a git submodule; pieces compile into both apps
Tests/                 unit tests, laid out like Vibe/
  AudioRender/         the audio suite: the real player, rendered with no device
  Support/             shared test helpers
  BenchComponents/     the component benchmarks, not tests
  iOSDriver/           the touch driver for the iOS simulator, not tests
  iOSSim/              the iOS shell's tests, hosted in the app on a simulator
Resources/             string catalogs, built-in themes, the app icon, the welcome track
docs/                  docs for users and contributors (docs/README.md lists them)
scripts/               build, check, string, release, App Store, web, and benchmark scripts
functions/             the website's Cloudflare Pages Functions, which count update checks
project.yml            the XcodeGen spec for every target
Makefile               every build, test, and check command
```

`Packages/WaveformCore/` sits beside `Vibe/`. It is the waveform engine, kept free of app types for reuse: the summary, its reads, the zoom steps and the raster. Both apps and the tests compile its sources.

## The subsystems

### Common

`Vibe/Common/` is what everything else is written in terms of. It holds no feature. `AppSettings` is every stored preference, over `NSUserDefaults`. `AppStats` is every stored counter. The macOS-only settings are the `(Mac)` category in `Mac/AppSettings+Mac`. The theme store is `Mac/Theme/AppSettings+Themes`, and `Mac/Theme/AppTheme` is the theme record. `VibeStrings.h` declares every user-facing string as a `STR_*` macro. `DocumentTypes` reads back the document types the apps declare. Read next: `Vibe/Common/AGENTS.md`. For themes, read `Common/Mac/AGENTS.md` and `Common/Mac/Theme/AGENTS.md`.

### Audio

`Vibe/Audio/` is the playback engine. There is no `AVAudioEngine`. Vibe decodes, mixes, and renders the audio itself. One output unit pulls the result. `AudioPlayer` is the transport: play, pause, seek, stop, and the delegate callbacks. Its categories own the rest. `+Pipeline` is the render pipeline's player-queue side. `+Prefetch` is the next file, opened early. `+State` is the getters, and `+Diagnostics` the reports. `AudioVoiceBus` decodes and mixes the voices. `AudioMasterBus` is the render function. `AudioOutputUnit` is the output unit. `AudioFileHandle` opens and reads one file. The engine takes any object that adopts `VibePlayableItem`: a file, its window, and the keys it is matched by. Read next: `Vibe/Audio/AGENTS.md`. Its section "The model in one page" is the place to start.

The DJ effects, the meter, and the fades are vibe-libs' (below). `Vibe/Audio/AGENTS.md` says how the player hosts the effects, the pitch fader's stage, and the meter. Each other feature beside the engine has its own directory and doc:

- **`Metadata/`**: `AudioTrackMetadataCache` is the facade over tags, their disk cache, and the playlist scan. `AudioTrackMetadataLoader` is the scan behind it. `TagLibAudioFile` reads tags through TagLib. `Artwork/` holds `AudioTrackArtwork` and `EmbeddedThumbnailCache`. `Artwork/FolderArt/FolderArtResolver` finds a cover beside the files, on macOS. Docs: `Audio/Metadata/AGENTS.md` and `Audio/Metadata/Artwork/FolderArt/AGENTS.md`.
- **`Waveform/`**: `AudioWaveformLoader` decodes a file into an `AudioWaveform`, and feeds each mono block to the observers its request lists. `AudioWaveformCache` owns the loaders and stores the results on disk through PINCache. The data is `Packages/WaveformCore`'s summary. Docs: `Audio/Waveform/AGENTS.md` and `Packages/WaveformCore/AGENTS.md`.
- **`Analysis/`**: `AudioBPMAnalyzer` and `AudioKeyAnalyzer` ride the waveform's decode pass as observers. The app's `Playlist/AudioAnalysisObservers.h` joins them to the decode, and each shell attaches them. Neither reads the file a second time. Key detection runs on macOS only. Doc: `Audio/Analysis/AGENTS.md`.
- **`Mac/Devices/`**: `AudioPlayer+Devices` binds the output unit to a device. `AudioPlayer+BitPerfect` is bit-perfect and exclusive output. The devices themselves come from vibe-libs: `AudioDeviceManager` tracks them, and `CoreAudioUtil` reads and writes them (`vibe-libs/audio/OutputDevices/Mac/`). Docs: `Audio/Mac/Devices/AGENTS.md` and `vibe-libs/audio/OutputDevices/AGENTS.md`.
- **`iOS/`**: `AudioPlayer+Recovery` rebuilds the output when the system changes the route. The `AVAudioSession` is managed by `AudioSessionController`, which comes from vibe-libs (`vibe-libs/audio/OutputDevices/iOS/`). Docs: `Audio/iOS/AGENTS.md` and `vibe-libs/audio/OutputDevices/AGENTS.md`.

### Loading

vibe-libs' `files/FileLoading` takes a path and hands back a readable `AudioFileHandle`, which the player's opener makes. The path may name a local file, a cloud placeholder that must download first, a file on a network share, or an Open URL link. `PlaceholderFiles` says whether a file is a placeholder. `Claim/AudioFileMaterializationCoordinator` owns materialization and playback handle opens. Metadata can also read remote byte ranges through the backend. It keeps one claim per path, decides which download may run, and puts the open the user is waiting on ahead of background reads. `Transfer/CloudFileMaterializer` runs one download that can be cancelled. `Transfer/CloudFileAvailability` says how much of a file is readable while it still downloads. `Transfer/NetworkReadAhead` reads a file on a network mount ahead of the player. `Transfer/CloudTransferRegistry` lists the files on the wire, and every loading bar reads it. `Vibe/Loading/` keeps the app's own transfers. `Net/` is the app's own HTTP: `HTTPTransferClient`, `RemotePlaceholderStore`, and `LinkStore` for Open URL. `iOS/Dropbox/` is the Dropbox account (`DropboxClient`) and its local mirror (`DropboxMirror`). Read next: `vibe-libs/files/FileLoading/AGENTS.md` for how the code works, `Vibe/Loading/AGENTS.md` for what stays here, and `docs/file-loading-spec.md` for the behavior it must keep.

### Playlist

`Vibe/Playlist/` is the playlist model and how its rows are made. `AudioTrack` is one row: a whole file, or a CUE sheet's window of one. It adopts `AudioTrackMetadataHolder`, which extends `VibePlayableItem`. So the engine can play it, and the metadata loader can install its tags. `Playlist` holds the rows, the current row, and the shuffle order. `trackEndSuccessor` is its one answer to what plays after a track ends. `FolderWalk` turns what the user opened into entries. It walks folders, follows links to folders, and expands playlist files. It runs on background workers and reads no setting. `PlaylistFile` reads M3U files and CUE sheets, including a sheet embedded in a FLAC, and writes M3U files. A CUE sheet becomes one entry per track, each a window of its file. An entry is a `PlaylistEntry` record, and `AudioTrack rowsForEntries:` makes the rows from them. `Mac/` is the macOS table (`PlaylistController`, `PlaylistTableView`) and the last-playlist store (`PlaylistFile+Session`). The iOS list is `Vibe/iOS/PlaylistViewController`. Read next: `Vibe/Playlist/AGENTS.md`, then `Playlist/Mac/AGENTS.md`.

### NowPlaying

`Vibe/NowPlaying/NowPlayingController` publishes the playing track to the system and takes remote commands back. The lock screen, Control Center, CarPlay, AirPods, and the Mac's media keys all go through it. It owns no playback state. `MainPlayerController+NowPlaying` drives it on macOS, and `PlaybackController+NowPlaying` on iOS. Read next: `Vibe/NowPlaying/AGENTS.md`.

### Controls

`Vibe/Controls/` holds the controls both apps draw the same way. `EqualizerIndicatorView` is the bars that mark the playing row. It reads levels through an `EqualizerLevelSource`. It polls only while audio plays and the row can be seen. `LoadingIndicator` draws the loading bar and shimmer on the waveform. `LoadingIndicatorView` draws the small loading pill in a row's number gutter. Read next: `Vibe/Controls/AGENTS.md`.

### WaveformUI

`Vibe/WaveformUI/` draws waveforms. `Audio/Waveform/` makes the data, and this directory draws it. `WaveformTheme` is the one place a theme or setting becomes waveform colors. `Renderers/` holds the styles. `WaveformRendererRegistry` maps a style's identifier to its renderer. `WaveformMorphEngine` eases the bars from one shape to the next. `Mac/WaveformView` is the macOS view across the window. `iOS/WaveformScrubberView` is the iOS scrubber, with the play position fixed at the center. Read next: `Vibe/WaveformUI/AGENTS.md`, then the doc in `Renderers/`, `Mac/`, or `iOS/`.

### Util

`Vibe/Util/` is code with no feature. If you can name the feature a file serves, it belongs in that feature's directory instead. `Formatters` builds the info lines. `Categories/` holds `NSString+CPPStrings`. `Mac/` and `iOS/` hold the AppKit and UIKit categories. The helpers another app could use are in vibe-libs' `core/Common`. `FilePaths` there compares paths by spelling, without touching the disk (`VibeComparablePath`). `NSURL+Hash`'s `cacheKey` keys the metadata and waveform caches. `StallWatch` samples stuck threads for the beta logs. Read next: `Vibe/Util/AGENTS.md`.

### Debug

`Vibe/Debug/` is the debug command channel. It lets a script drive and inspect a running Debug build of either app. On macOS the command is `Vibe --debug-cmd <command>`. For the simulator it is the `vibe-debug` skill's `debug-ios.sh`. Nearly every file is wrapped in `#if DEBUG`. A Release build compiles them to empty objects. `Channel/` is the transport. `Verbs/` holds the commands both apps answer. `Oracles/` holds the consistency checks. `Simulators/` holds stand-ins for a cloud provider and an HTTP host, and the manual render pump the audio tests use in place of a device. `Seams/` holds the `+Debug` categories that open a shipping class to the channel and the tests. Read next: the `vibe-debug` skill to use the channel, and `Vibe/Debug/AGENTS.md` to change it.

### The macOS shell

`Vibe/Mac/` is the macOS app shell, with one directory per piece. `App/` holds `AppDelegate` and the services it owns. Those are the open funnel (`OpenBurstCoalescer`, `OpenRequestCoordinator`), sandbox folder grants (`FolderAccessManager`), Open URL (`OpenLinkWindowController`), updates through Sparkle (`AppDelegate+Updates`), and Save Debug Info (`DebugInfo`). `MainWindow/` is the player window. `MainPlayerController` coordinates it, and each of its categories owns one concern: `+Playlist`, `+Transport`, `+PlayerEvents`, `+Delivery`, `+Window`, `+Menus`, `+Settings`, `+NowPlaying`, and `+Convert`. `Menu/` builds the menu bar in code (`MainMenuBuilder`), over vibe-libs' `ui/Shortcuts`. `Controls/` holds the artwork view and the pitch controls, such as `PitchFaderView`. The other AppKit controls, such as `SymbolButton` and the drawn slider and switch, are vibe-libs' `ui/Controls`. `Settings/` is the Settings window (`SettingsWindowController`) and its panes. The generic window under it, with the sidebar, the pane base, and the form views, is vibe-libs' `ui/SettingsWindow`. The Keyboard Shortcuts pane is `ui/Shortcuts`' too. `Settings/Themes/` is the theme list and editor. `About/` is the About window. `Convert/` is Convert to FLAC (`AudioFileConverter`). Read next: `Vibe/Mac/App/AGENTS.md` and `Vibe/Mac/MainWindow/AGENTS.md`. The window's layout and chrome are in `Vibe/Mac/MainWindow/LAYOUT.md`.

### The iOS shell

`Vibe/iOS/` is the iPhone and iPad app shell. The playlist starts from a folder, file, or playlist file and can hold additions. `PlaybackController` is the model. It owns the `AudioPlayer`, the `Playlist`, the metadata cache, the audio session, and Now Playing. It draws nothing, and every screen borrows it. `FolderSession` owns the locations the user picked: their security scopes, their bookmarks, and their listing. `PlaybackController+Opening` joins the two. `RootViewController` holds the tabs, the mini player (`MiniPlayerView`), and the now-playing card. `PlaylistViewController` is the Playlist tab. `Files/`, `Player/`, `Search/`, `Settings/`, and `Widget/` each have their own doc. The iOS halves of shared subsystems live with those subsystems, such as `Audio/iOS/` and `Loading/iOS/Dropbox/`. Read next: `Vibe/iOS/AGENTS.md`.

### The widget

`VibeWidget/` is the Home Screen and Lock Screen widget extension, written in Swift. It has no engine and never reads an audio file. It draws the `VibeWidgetState` snapshot the app writes into a shared app group. The app's writer is `Vibe/iOS/Widget/WidgetPublisher`. Read next: `VibeWidget/AGENTS.md` and `Vibe/iOS/Widget/AGENTS.md`.

### vibe-libs

`vibe-libs/` is a git submodule: [vibe-libs](https://github.com/cmicali/vibe-libs), a public toolbox of small libraries that Vibe and another app share. Each library is a piece. A piece's sources compile into both apps as their own, through the templates in `vibe-libs/vibe-libs.yml`. Nothing builds differently.

**Vibe uses twelve pieces today, besides the vendored libraries.** `core/Common` holds the log, realtime-effects and signpost macros, which the prefix header imports. It also holds the featureless helpers: path spelling, the disk key, the work lanes, the stall sampler, the update timer, build provenance, and the form-label colon rule. `core/Graphics` holds the image, color, and font helpers. Its `PlatformTypes.h` defines `VibeImage` and `VibeColor`. A shared header can then hold an image without AppKit or UIKit. `audio/AudioTypes` holds the words the audio code shares: the playable-item protocol, the CUE window math, the musical key, the format names, and `PlayableExtensions`, every audio extension the apps play. `audio/DSP` holds the pitch fader's varispeed and the fades. `audio/OutputDevices` holds the mac's output devices and HAL reads, and the iOS audio session and its route rules. `audio/FX` holds `AudioFX`, the DJ effects on the master bus: a low-kill filter, a reverb, and two tempo-synced delays. `audio/Meter` holds `AudioLevelMeter`, which reads the final output inside the render and feeds the equalizer bars.

`files/FileLoading` holds the file-open path, from a path to a readable file, with its debug seams and the fake cloud. `files/DiskCache` holds the bounded disk cache that the metadata and waveform caches build on. `ui/Controls` holds the mac's symbol button, drawn controls, image views, link label, and window resize timing. `ui/SettingsWindow` holds the mac's generic settings window and form views. `ui/Shortcuts` holds the shortcut encoding, the keyboard layout, and the Keyboard Shortcuts pane. Every vendored library but Sparkle is a piece under `third_party/` too. Controls, SettingsWindow, and Shortcuts are macOS only. Only the mac app lists them.

More of Vibe's shared code moves there piece by piece (`docs/future/vibe-libs.md`). `make project` checks the submodule out in a fresh clone or worktree. A change to a piece is made in vibe-libs first. Vibe then bumps the submodule. Read `vibe-libs/AGENTS.md` and the piece's own doc first.

### Third-party code

There is no package manager. Vendored code is vibe-libs' `third_party/`: a subset of TagLib, PINCache and PINOperation, r8brain-free-src, dr_mp3, dr_flac, dr_wav, libvorbis, and libogg, each a piece of its own. Its template carries its compiler flags, and both apps list it. The three dr_ libraries carry fixes of Vibe's own. Read the piece's `AGENTS.md` before changing one. `Vibe/ThirdParty/` holds only the prebuilt Sparkle framework, until the Updates piece moves. [`THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md) lists every license.

### Tests, resources, and scripts

`make test` runs `VibeTests` and the cloud-runner oracle tests. These tests need no window, no audio device, and no running app. `make test-audio` runs `VibeAudioTests` from `Tests/AudioRender/`. It drives the real player and FX with no device. It checks the output with full PCM comparisons and signal-quality checks. A test lives in the `Tests/` directory that matches the code it tests. Read `Tests/AGENTS.md` before adding one. A check that needs the running app goes through the debug channel instead.

`Resources/` holds the string catalogs, the built-in themes (`Themes/*.json`), the app icon, and the bundled welcome track. `make strings` writes the keys, English text and comments in `Localizable.xcstrings`. Translations are edited in the catalog. Read `Resources/AGENTS.md`, and `Resources/Themes-README.md` before making a theme.

`scripts/` holds what the `Makefile` runs. Each job has its own directory: `build/`, `checks/`, `strings/`, `test/`, `release/`, `appstore/`, `web/`, `screenshots/`, `bench/`, `analysis/`, and `docs/`. Most scripts have a `make` target, and the `Makefile` comments each one. Releases go through the `vibe-release` skill.

## From open to sound

This is the path a file takes from the moment the user opens it to the moment it plays. Each step names the class and the file to read.

```
 the user opens a file or folder
   │
 shell open funnel ──► FolderWalk ──► entries ──► rows (AudioTrack) ──► Playlist
   │
 AudioPlayer play:                     player queue
   │
 AudioFileMaterializationCoordinator   vibe-libs' files/FileLoading/Claim
   │   stage 1: make the file readable files/FileLoading/Transfer
   │   stage 2: open it
   ▼
 AudioFileHandle                       parser, decoder, stream or read-ahead
   │
 AudioVoiceBus                         decode pool → ring → gain → mix
   │
 VibeMasterBusRender                   voice bus → [varispeed] → [FX] → [meter] → [volume]
   │
 AudioOutputUnit                       HALOutput on macOS, RemoteIO on iOS
```

### 1. The open funnel

**On macOS** every way a file arrives lands in `AppDelegate` (`Mac/App/AppDelegate.m`). That covers a Finder double-click, ⌘O, Add to Playlist, Open Recent, a drop on the window, Open URL, and a launch argument. `OpenBurstCoalescer` joins the batches that Launch Services splits one open into. `OpenRequestCoordinator` delivers finished expansions in order, and drops any that a newer open replaced. `openURLsWithRestoredAccess:token:` reads the folder sort setting on main. It hands the URLs to `FolderWalk expandAndFilterList:sortedBy:completion:` (`Playlist/FolderWalk.m`). The walk runs on a background queue. It returns `PlaylistEntry` records on that queue, and the funnel makes an `AudioTrack` row of each there before it goes to main. `deliverExpandedRows:folderCount:appending:fromURLs:` passes them to `MainPlayerController`'s `play:` or `addTracks:`. `loadTracks:selectingIndex:startPaused:` loads them into the model through `PlaylistController loadTracks:selectingIndex:`. Then `playStartPaused:` calls `AudioPlayer play:`.

**On iOS** every open starts in `PlaybackController+Opening`. It calls `FolderSession` (`iOS/FolderSession.m`). The prologue, `beginOpenURLs:appending:expandsFile:grantedFolder:`, runs on main. It finds the grant that covers each URL and reads the folder sort setting. The worker, `openURLsOnWorkQueue:`, lists the entries through `FolderWalk entriesInDirectory:sortedBy:`, makes the rows, and mints the bookmarks. `finishOpenIntent:` lands the result on main. The delegate call `folderSession:didOpenTracks:folderURL:selectedURL:restored:` hands the rows to `Playlist replaceAllWithTracks:startingAtIndex:`. Then `playCurrentTrack` (`iOS/PlaybackController.m`) activates the audio session and calls `AudioPlayer play:`.

Read `Vibe/Mac/App/AGENTS.md` ("Opening files is a funnel, not an event") and `Vibe/iOS/AGENTS.md` ("FolderSession").

### 2. The player takes the request

`AudioPlayer play:` (`Audio/AudioPlayer.m`) gives the play a submission identity and queues it on the serial player queue. `PlaybackRequestCoordinator` gives the open its own identifier. It holds the open's row, its intent (playing or paused, and the start position), and whether it is slow. `submitOpenOnQueueForTrack:openRequestId:` asks the loading coordinator for a handle. It also arms the open's deadline. An open with no progress for 60 seconds is abandoned. Each movement of the download extends the deadline (`vibe-libs/files/FileLoading/Claim/AudioFileOpenTimeoutMath.h`). A File Provider placeholder shows Loading as soon as it is classified as dataless. Other opens show Loading after half a second.

Read `Vibe/Audio/AGENTS.md` ("AudioPlayer" and "Opening a file").

### 3. Loading

`AudioFileMaterializationCoordinator openURL:purpose:opener:completionQueue:onDataless:completion:` (vibe-libs' `files/FileLoading/Claim/`) owns the rest. Every request is keyed by the file's standardized path. The playback open, the prefetch, and the metadata scan all join one claim per path. Those requests share the same materialization work.

**Stage 1 makes the file readable.** A bounded probe asks `PlaceholderFiles isDatalessFile:`. A file found local needs no transfer lane or download. A placeholder waits for a transfer lane. Then it is published to `CloudTransferRegistry`, and its row shows a loading bar. `CloudFileMaterializer` (vibe-libs' `files/FileLoading/Transfer/`) runs the download. A File Provider placeholder, such as an iCloud Drive file, downloads through `NSFileCoordinator`. A remote placeholder, such as an Open URL link or a file in the iOS Dropbox mirror, downloads through its store's fetch (`Loading/Net/`). A remote file can become readable before its download completes. While the user waits on an open, background downloads for metadata yield.

**Stage 2 opens the handle** (`AudioFileMaterializationCoordinator+HandleOpen.m`). At most six handle opens run at once. Each calls `AudioFileHandle initForReading:interleaved:interrupted:error:` on a worker. The handle is delivered back on the player queue.

Read `vibe-libs/files/FileLoading/AGENTS.md` ("One claim, two stages" and "The transfer registry") and `docs/file-loading-spec.md`.

### 4. AudioFileHandle

`AudioFileHandle` (`Audio/AudioFileHandle.m`) is one open file. The handle first reads the file's opening bytes. FLAC goes to dr_flac, WAV, W64, RF64 and AIFF to dr_wav, and Ogg Vorbis to libvorbis (`AudioFileHandle+Stream.m`). MPEG goes to dr_mp3, and the handle frames it itself (`AudioFileHandle+MPEG.m`). Each answers the file's facts itself. Any other file opens CoreAudio's parser for its facts (`openParserWithError:`), and Apple's decoders play it. AAC, ALAC and Opus are such files. A file those decoders refuse reaches the parser too. Playback refuses it there unless it holds a coding none of them decodes, such as GSM in a WAV.

A handle reads its bytes in one of three ways:

- A local file is read directly.
- A file still downloading is read from its part file. Each read waits for the bytes it needs (`CloudFileMaterializer availabilityForURL:`, `CloudFileAvailability`).
- A file on a network mount is read from the blocks `NetworkReadAhead` fetches ahead on its own thread.

The availability waits can be interrupted (`interruptReads`). Network read-ahead isolates a stalled OS read from the decoder. The OS read itself may remain blocked.

Read `Vibe/Audio/AGENTS.md` ("The decoders", "Reading a file still downloading", and "Reading ahead on a network mount").

### 5. Settlement

`finishPlayOnQueueWithFile:error:openRequestId:` (`AudioPlayer.m`) receives the handle on the player queue. It drops the result of an open that a newer play replaced or that timed out. `ensureSourceSegmentOnQueueRebuilt:` (`AudioPlayer+Pipeline.m`) builds the render pipeline at the first settlement. It reuses a compatible source segment. Format or mode changes can require a rebuild. `startVoiceOnQueueForFile:…` starts a voice on the voice bus. `startOutputOnQueue:` starts the output unit. The player publishes Playing, or Paused for a parked start. It sends `didStartPlaying:` to the shell on main. The delivery is dropped if a newer play was submitted meanwhile (`submittedPlayIsCurrent:`).

### 6. The voice bus

A voice is one file being rendered. `AudioVoiceBus` has eight slots. Each slot holds a ring buffer of at least one second. The work is split across three files and three kinds of thread.

- **The queue side** (`AudioVoiceBus.m`) runs on the player queue. It starts and kills voices, sets their gain ramps, and hands the next file to a voice for a gapless change. The player's drain (`drainVoiceBusOnQueue`, in `AudioPlayer+Pipeline.m`) collects each voice's events: it went live, it crossed into the next file, or it ended.
- **The decoder side** (`AudioVoiceBus+Decoder.m`) runs on a pool of eight serial decode queues. It reads the file through its handle and fills the voice's ring in turns of 4096 frames. It converts every file to the bus format: float32 with up to two channels at the output's rate. A channel difference is mixed down first. A rate difference goes through `VibeResampler` (`AudioResampler.mm`). It runs r8brain-free-src.
- **The audio thread** (`AudioVoiceBusRender.m`) runs `VibeVoiceBusRender`. It mixes every live voice into the output buffers at its per-frame gain. It is plain C under `CA_REALTIME_API`. A lock, an allocation, or an Objective-C message there is a build error.

Crossfades, the declick, pauses, and seeks are all gain ramps on voices. A seek starts a new voice at the target and fades the old one out beside it.

Read `Vibe/Audio/AGENTS.md` ("The voice bus", "Threading", and "Crossfades, pauses and seeks").

### 7. The master bus

`VibeMasterBusRender` (`Audio/AudioMasterBus.m`) is the one render function on both platforms. For each slice of output it runs these stages in order:

1. The voice bus, through `VibeVoiceBusRender`.
2. The varispeed on macOS (`VibeVarispeedRender`, `vibe-libs/audio/DSP/AudioVarispeed.m`). At zero pitch it passes samples through and records history for a later pitch change.
3. The hosted FX chain (`VibeFXChainRender`, `vibe-libs/audio/FX/AudioFX.m`). Released effects pass samples through once their tails finish.
4. The meter, while the equalizer bars want levels or the beta signal probe is capturing (`VibeLevelMeterRender`, `vibe-libs/audio/Meter/AudioLevelMeter.m`).
5. The volume, skipped once settled at full volume. Debug silent mode forces zero output here.

After pitch transitions and FX tails settle, zero pitch and full volume preserve the voice bus's samples. Debug silent mode still mutes them.

Read `Vibe/Audio/AGENTS.md` ("The model in one page"), `vibe-libs/audio/FX/AGENTS.md`, and `vibe-libs/audio/Meter/AGENTS.md`.

### 8. The output unit

`AudioOutputUnit` (`Audio/AudioOutputUnit.m`) hosts Apple's output audio unit. Its render callback calls `VibeMasterBusRender`. On macOS it is HALOutput, bound to the chosen device by `AudioPlayer+Devices` (`Audio/Mac/Devices/`). Bit-perfect output may also switch the device to the file's rate (`AudioPlayer+BitPerfect`). On iOS it is RemoteIO, routed by `AVAudioSession`. `AudioPlayer+Recovery` (`Audio/iOS/`) follows the session, and vibe-libs' `AudioSessionController` manages it. Binding, configuring, starting, and stopping the unit run on its own serial queue. A slow device then cannot hold the player queue.

Read `Vibe/Audio/Mac/Devices/AGENTS.md`, `Vibe/Audio/iOS/AGENTS.md`, and `vibe-libs/audio/OutputDevices/AGENTS.md`.

### 9. After the start

Each shell handles `didStartPlaying:`. On macOS it is `performPerTrackRefreshForStartedTrack:` (`MainPlayerController+PlayerEvents.m`). On iOS it is `PlaybackController+PlayerEvents.m`. The shell asks the player to prefetch what follows (`AudioPlayer prefetchTrack:` with `Playlist.trackEndSuccessor`). The prefetch opens the next file early through the same coordinator. For a gapless change, the player queues that file on the current voice (`AudioPlayer+Prefetch.m`). The shell then asks for the playing track's metadata and starts the deferred metadata scan. The scan waits for the open to settle, with a two-second fallback (`scheduleDeferredMetadataLoad`). Its downloads also yield while the user waits on an open. The macOS shell also starts the waveform load (`AudioWaveformCache loadWaveformForTrack:`).

Read `Vibe/Audio/AGENTS.md` ("Prefetch and gapless") and `Vibe/Audio/Metadata/AGENTS.md`.

### Who runs where

| Thread or queue | What runs there |
| --- | --- |
| Main | both shells, all UI, and every `AudioPlayer` delegate callback |
| The player queue (serial) | the transport, open settlement, and the voice bus's drain |
| The coordinator's state queue and workers | claims, probes, downloads, and handle opens |
| The decode pool (eight serial queues per bus) | file reads and format conversion |
| The output unit's queue (serial) | device binding, configuration, start, and stop |
| The audio thread | `VibeMasterBusRender` and everything it calls |
| One read-ahead thread per handle | reads of a file on a network mount |

## Where to look for what

| I want to change | Read | Start in |
| --- | --- | --- |
| A setting, or add one | `Common/AGENTS.md` | `Common/AppSettings.h` or `Common/Mac/AppSettings+Mac.h` |
| A user-facing string | [localization.md](localization.md), the `vibe-strings` skill | `Common/VibeStrings.h`, then `make strings` |
| Which formats play | `Audio/AGENTS.md` (the decoders) | `vibe-libs/audio/AudioTypes/PlayableExtensions.m`, `Audio/AudioFileHandle.m` |
| How a file is decoded | `Audio/AGENTS.md`, each decoder's doc in `vibe-libs/third_party/` | `Audio/AudioFileHandle.m`, `Audio/AudioFileHandle+MPEG.m`, `Audio/AudioFileHandle+Stream.m` |
| Play, pause, seek, or crossfade | `Audio/AGENTS.md` | `Audio/AudioPlayer.m`, `vibe-libs/audio/DSP/FadeMath.h` |
| Gapless playback and prefetch | `Audio/AGENTS.md` (Prefetch and gapless) | `Audio/AudioPlayer+Prefetch.m`, `Audio/AudioPrefetchRules.h` |
| What plays next, repeat, or shuffle | `Playlist/AGENTS.md` | `Playlist/Playlist.m` |
| Mixing and real-time code | `Audio/AGENTS.md` (The voice bus, Threading) | `Audio/AudioVoiceBusRender.m`, `Audio/AudioMasterBus.m` |
| Sample-rate conversion | [audio-quality.md](audio-quality.md) | `Audio/AudioResampler.mm` |
| Decoder conformance against public test files | the `vibe-audio-quality` skill, [audio-quality.md](audio-quality.md) | `Tests/AudioRender/AudioQualityCorpusTests.m` |
| DJ effects or pitch | `vibe-libs/audio/FX/AGENTS.md`, `vibe-libs/audio/DSP/AGENTS.md`, `Audio/AGENTS.md` (The FX segment and the pitch stage) | `vibe-libs/audio/FX/AudioFX.m`, `vibe-libs/audio/DSP/AudioVarispeed.m` |
| Output devices or bit-perfect output | `Audio/Mac/Devices/AGENTS.md`, `vibe-libs/audio/OutputDevices/AGENTS.md` | `Audio/Mac/Devices/AudioPlayer+Devices.m`, `AudioPlayer+BitPerfect.m`, `vibe-libs/audio/OutputDevices/Mac/AudioDeviceManager.m` |
| The iOS audio session and routes | `vibe-libs/audio/OutputDevices/AGENTS.md`, `Audio/iOS/AGENTS.md` | `vibe-libs/audio/OutputDevices/iOS/AudioSessionController.m` |
| Cloud downloads, their order, the loading bar | `vibe-libs/files/FileLoading/AGENTS.md`, [file-loading-spec.md](file-loading-spec.md) | `vibe-libs/files/FileLoading/Claim/AudioFileMaterializationCoordinator.m` |
| Playing a file that is still downloading | `vibe-libs/files/FileLoading/AGENTS.md` (CloudFileAvailability) | `vibe-libs/files/FileLoading/Transfer/CloudFileAvailability.m` |
| Files on a network share | `vibe-libs/files/FileLoading/AGENTS.md` (The network-mount read-ahead) | `vibe-libs/files/FileLoading/Transfer/NetworkReadAhead.m` |
| Open URL and links | `Loading/Net/AGENTS.md`, `Mac/App/AGENTS.md` | `Loading/Net/LinkStore.m` |
| Dropbox on iOS | `Loading/iOS/Dropbox/AGENTS.md` | `Loading/iOS/Dropbox/DropboxMirror.m` |
| Tags, the metadata cache, or the scan | `Audio/Metadata/AGENTS.md` | `Audio/Metadata/AudioTrackMetadataLoader.m` |
| Artwork and row thumbnails | `Audio/Metadata/AGENTS.md` | `Audio/Metadata/Artwork/AudioTrackArtwork.m` |
| Cover images beside the files | `Audio/Metadata/Artwork/FolderArt/AGENTS.md` | `Audio/Metadata/Artwork/FolderArt/FolderArtResolver.m` |
| Tempo or key detection | `Audio/Analysis/AGENTS.md` | `Audio/Analysis/AudioBPMAnalyzer.mm`, `Audio/Analysis/AudioKeyAnalyzer.mm` |
| Waveform data or its cache | `Audio/Waveform/AGENTS.md`, `Packages/WaveformCore/AGENTS.md` | `Audio/Waveform/AudioWaveformLoader.mm` |
| How a waveform looks, or a new style | `WaveformUI/AGENTS.md`, `WaveformUI/Renderers/AGENTS.md` | `WaveformUI/Renderers/WaveformRendererRegistry.mm` |
| The equalizer bars | `Controls/AGENTS.md`, `vibe-libs/audio/Meter/AGENTS.md` | `Controls/EqualizerIndicatorView.m` |
| How files open on macOS | `Mac/App/AGENTS.md` | `Mac/App/AppDelegate.m` |
| The folder walk, its sort order, CUE or M3U | `Playlist/AGENTS.md` | `Playlist/FolderWalk.m`, `Playlist/PlaylistFile.m`, `Playlist/PlaylistFile+CUE.m` |
| The macOS player window | `Mac/MainWindow/AGENTS.md`, `Mac/MainWindow/LAYOUT.md` | `Mac/MainWindow/MainPlayerController.m` |
| Keyboard shortcuts and skips | `Mac/MainWindow/Transport/AGENTS.md` | `Mac/MainWindow/Transport/TransportKeyMonitor.m` |
| The macOS playlist table | `Playlist/Mac/AGENTS.md` | `Playlist/Mac/PlaylistController.m` |
| The menu bar | `Mac/Menu/AGENTS.md` | `Mac/Menu/MainMenuBuilder.m` |
| The macOS Settings window | `Mac/Settings/AGENTS.md` | `Mac/Settings/SettingsWindowController.m` |
| Themes | [themes.md](themes.md), `Common/Mac/Theme/AGENTS.md` | `Common/Mac/Theme/AppTheme.m`, `Resources/Themes/` |
| Convert to FLAC | `Mac/Convert/AGENTS.md` | `Mac/Convert/AudioFileConverter.m` |
| Sandbox folder grants on macOS | `Mac/App/AGENTS.md` (Sandbox grants) | `Mac/App/FolderAccessManager.m` |
| Updates through Sparkle | `Mac/App/AGENTS.md` (Updates) | `Mac/App/AppDelegate+Updates.m` |
| The iOS model and opening folders | `iOS/AGENTS.md` | `iOS/PlaybackController.m`, `iOS/FolderSession.m` |
| The iOS now-playing card | `iOS/Player/AGENTS.md`, `WaveformUI/iOS/AGENTS.md` | `iOS/Player/PlayerViewController.m` |
| The iOS Files tab, Favorites, Search, or settings | the `AGENTS.md` in `iOS/Files/`, `iOS/Search/`, or `iOS/Settings/` | that directory |
| The widget | `VibeWidget/AGENTS.md`, `iOS/Widget/AGENTS.md` | `iOS/Widget/WidgetPublisher.m` |
| The lock screen and media keys | `NowPlaying/AGENTS.md` | `NowPlaying/NowPlayingController.m` |
| A debug command | the `vibe-debug` skill, `Debug/AGENTS.md` | `Debug/Verbs/`, `Debug/Mac/`, `Debug/iOS/` |
| Tests | `Tests/AGENTS.md` | the `Tests/` directory that matches the code |
| Performance | the `vibe-perf` skill, [performance.md](performance.md) | `Tests/BenchComponents/` |
| Targets and build settings | the root `AGENTS.md` (Building) | `project.yml`, `Makefile` |

Paths in the "Read" and "Start in" columns are under `Vibe/` unless they name a top-level directory or a doc here in `docs/`.

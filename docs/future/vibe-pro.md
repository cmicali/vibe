# Future: Vibe Pro

**Status: scoped 2026-10-08, nothing built.** A second product on the same engine: Vibe plus a library, rekordbox support and, where it is possible at all, streaming. The scope was read off the code at `main` and off `streaming-any-source.md`, `ios-google-drive.md` and `dropbox-shared-links.md`, which it builds on. Nothing here was prototyped.

Vibe's own position stays what the issue template says: a player for local files, with no library, no accounts and no streaming services. Vibe Pro is where those three go. Both ship from this repository, on one engine and one waveform system, under one version number.

## Recommendation in one table

| Part | Build | Size | Order |
| --- | --- | --- | --- |
| The shared libraries | Two static library targets, `VibeAudio` and `VibeWaveform`, cut out of the directories both apps already compile | L (4 to 6 weeks) | First. Everything else links them |
| The library | A SQLite catalog over watched folders, a browser window, stored playlists, ratings and play counts, feeding the existing play queue | XL (8 to 12 weeks) | Second. The product is not Pro without it |
| rekordbox | Read `rekordbox.xml` and a USB export (`export.pdb` plus ANLZ); write `rekordbox.xml`. Markers, grid-aligned skips and loops in the engine | L (6 to 9 weeks, the engine half included) | Third. Needs the catalog to land in |
| Streaming files | The `streaming-any-source.md` plan, plus a media server source (Subsonic, Jellyfin, Plex, WebDAV) | L (6 to 10 weeks) | Fourth, and shared with Vibe |
| Streaming services | Nothing, until a partner agreement exists | none | Not engineering |

Sizes are for one developer with agents. They are estimates from the code, not measurements.

Two decisions change the plan more than anything else, and both are the maintainer's:

1. **Two products, or one product with an in-app purchase.** This document assumes two, because that is what was asked for and what the positioning says. One product with a paid unlock removes the whole multi-target build and most of the library split's reason to exist. The cost difference is about four weeks. See "Options weighed".
2. **Whether rekordbox's live `master.db` is ever read.** It is encrypted with a static key that third-party tools extract from the rekordbox install. This document keeps it out and reads the official XML bridge and the unencrypted USB export instead. See "rekordbox".

## Part 1: the shared libraries

### What is shared today, and how

Both apps already compile the same engine. `project.yml` lists one recursive source entry per shared subsystem, and the directory is the platform boundary (root `AGENTS.md`). So the mac app and the iOS app share `Audio/`, `WaveformUI/`, `Playlist/`, `Common/`, `System/`, `Util/`, `Controls/` and `Debug/` by compiling the same files twice. A third and fourth app target could share them the same way, by listing the same entries. That is the cheapest possible Vibe Pro build, and it is the fallback if the library split stalls.

What the split adds is a real boundary. Today Xcode's project-wide headermap lets any file import any header by basename, so `make check-layout`'s fourth assertion exists to catch the imports that should not compile. A library target makes the compiler the authority: a header the library does not export cannot be imported. It also builds the engine once per platform instead of once per app, it gives the two test targets one thing to link instead of the 91 and 38 source files they enumerate today, and it names the engine's API, which is what a second product needs to stay on it.

The sizes involved:

| Directory | Files | Lines | Goes to |
| --- | --- | --- | --- |
| `Vibe/Audio/` | 121 | 33,252 | `VibeAudio`, except `Waveform/` and `Mac/Convert/` |
| `Vibe/Audio/Waveform/` | 7 | 2,211 | `VibeWaveform` |
| `Vibe/WaveformUI/` | 29 | 5,537 | `VibeWaveform` |
| `Vibe/System/` | 12 | 2,083 | `VibeAudio` (the cloud half); `NowPlayingController` stays with the shells |
| `Vibe/Playlist/` (shared half) | 4 | 1,939 | `VibeAudio`: `AudioTrack` is its row |
| `Vibe/Common/`, `Vibe/Util/`, `Vibe/Controls/` | the featureless parts | | `VibeAudio` takes what the engine imports; the rest stays shared source |
| `Vibe/Debug/` (engine half) | 21 | | `VibeAudio` and `VibeWaveform`, still wrapped in `#if DEBUG` |

### The two libraries

**`VibeAudio`** is the player, the file handle and decoders, loading, materialization, the transfer registry, metadata and artwork, analysis, levels, FX, the mac device half, the iOS session half, `AudioTrack`, `Playlist` and `PlaylistFile`, and the vendored r8brain, dr_libs, TagLib and PINCache. Its public surface is `AudioPlayer.h`, `AudioTrack.h`, `AudioTrackMetadata.h`, `AudioTrackMetadataCache.h`, `Playlist.h`, `PlaylistFile.h`, `AudioFX.h`, `CloudTransferRegistry.h`, `CloudFileMaterializer.h`, `AudioLoadingConfiguration.h`, the two platform categories and the `*Rules.h` headers the shells already call.

**`VibeWaveform`** is the data (`AudioWaveform`, `AudioWaveformLoader`, `AudioWaveformCache`) and the rendering (`WaveformTheme`, `Renderers/`, the mac view, the iOS scrubber). It links `VibeAudio` for the file handle, the work scheduler, the track and the cache key. It stays ObjC++ inside and ObjC at its boundary, as `WaveformUI/AGENTS.md` already requires.

Two libraries rather than one because the two have different consumers: the home-screen widget's bakes and a future render-only tool want `VibeWaveform` without a player, and a conversion or scan tool wants `VibeAudio` without a view. One library would also be a 45,000-line module with every app shell's concern in it. Three would be a `VibeCommon` nobody asked for.

### What has to be cut

Every import out of the engine into a shell concern is a cut. Found by reading the imports. The counts are today's.

| From | Into | Sites | The cut |
| --- | --- | --- | --- |
| `Audio/` | `AppSettings` | 9 reads: `declick`, `appleMPEGDecoder`, `analyzeBPM`, `analyzeKey`, `useFolderArt`, `carryOutputModesFromDeviceUID`, `convertAsksWhereToSave`, and two `sharedInstance` | Each becomes a value the shell pushes, as `AudioPlayer.declick` and `AudioFileHandle.appleMPEGDecoder` already are, or a provider block, as the waveform cache's `VibeWaveformAnalysisProvider` and the folder-art resolver's enabled provider already are. The pattern exists; the nine sites join it |
| `Audio/Metadata/FolderArt/` | `FolderAccessManager` (`Mac/App/`) | 1 | A `canReadInsideDirectory` block the shell installs, the shape `NSURLUtil`'s launch-installed handler blocks already take |
| `Audio/` | `VibeStrings.h` | 14 macros: the error strings in `AudioErrorRules.h`, the cue-row and bitrate labels, Convert's menu strings | The engine reports `VibeAudioError` codes, which it already defines, and the shells localize. The cue-row and bitrate labels move to `Formatters`-side code in the shells. Convert leaves the library |
| `Audio/Mac/Convert/` | menus, the sandbox, `NSUndoManager` | | Convert is a mac feature over the engine's writer. It moves to `Vibe/Mac/MainWindow/Convert/` beside its UI and links the library. `AudioFileHandle`'s writing half stays in the library |
| `WaveformUI/` | `AppSettings`, `AppSettings+Mac`, `AppTheme` | the mac view 10 reads, the scrubber 7, the renderers about 10 | Each view takes a resolved `WaveformTheme`, a style identifier and the few switches as properties. `themeForAppTheme:isDark:artworkColor:` moves to the mac shell, which owns `AppTheme` |
| `WaveformUI/` | `Controls/LoadingIndicator` | | `Controls/` goes into `VibeWaveform`'s source list. It is already AppKit-free and UIKit-free apart from the aliases |
| `Audio/` | `Debug/` categories and `VibeManualRenderPump` | 62 `#if DEBUG` blocks across 13 files | The engine's debug half moves into the library. The declaration-only categories keep working, since their implementations already live in the shipping files under `#if DEBUG` |

A library may not import `AppSettings` at all. That is the one rule the split adds, and `make check-layout` enforces it by reading the library targets' import lists.

### Build shape

- **XcodeGen static library targets**, `type: library.static`, with `platform: [macOS, iOS]` so XcodeGen makes a target per platform. Static, not framework: no embedding, no bundle, no dyld cost at launch, and `NSLocalizedString` keeps reading the main bundle. The vendored per-file flags (`-O3` on r8brain and the dr_libs, the PIN cache's ARC exceptions) stay where they are, since the entries move into the library target as they are.
- **TRAP: a static library drops categories the app never references by class.** Every app target carries `OTHER_LDFLAGS: -ObjC`, or `NSURL+Hash` and every `+Debug` category silently vanish at link.
- **The prefix header is the library's too.** It carries only macros, and the libraries need `LogInfo` and the realtime brackets.
- **`VibeGitInfo.h` stays app-side.** Only `NSBundle+BuildInfo` reads it, and that category is a shell concern.
- **The tests link the libraries.** `VibeTests` stops enumerating 91 sources; `VibeAudioTests` stops enumerating 38. The one casualty is `VibeTests`' deliberate `AudioTrackMetadata` decoy, which exists because the real class is ObjC++ over TagLib. With the real class linked, the loader tests' duck fake still works, and the decoy's fail-loud constructor becomes a test on the real class refusing a parse off the test's thread. `Tests/AGENTS.md`'s decoy paragraph goes.
- **`make analyze` adds the library targets.** Findings outside `ThirdParty/` still fail it.
- **`make check-layout` learns targets of two kinds.** A shared directory is listed in every app target of its product, or in the one library that owns it. Assertion three becomes a product-by-platform matrix.
- **The benchmarks and the stress tools change nothing.** `VibeBenchComponents` drives production code in-process and links the libraries as the tests do.

### The guarantees it touches

- **"The waveform theme always beats the style's built-in palette, and is resolved in one place."** The rule survives; where it is resolved moves. `WaveformTheme` stays the one home of identifier-to-colors, inside `VibeWaveform`. "Each view resolves settings + appearance + the settled artwork color" becomes "each shell resolves and hands its view the result". The `album_art` delivery through the artwork install path is unchanged, since the install is the view's.
- **"Four features are macOS-only, each switched off at one place."** Unchanged, and the switches are now the pushed values above, so a fifth would be one more property rather than a `#if`.
- **No new guarantee.** The split retires the headermap trap in the layout rule's prose, since the compiler holds it.

### Budget

New files: two umbrella headers. New types: none. New targets: two libraries, each two platforms. Removed or unified: the two test targets' source lists, the `AudioTrackMetadata` decoy, nine settings reads and one access-manager reach out of the engine, fourteen string macros out of the engine, the headermap clause of the layout rule. Honest gap: `AudioPlayer+Devices` and `AudioSessionController` stay the library's platform halves rather than becoming injected outputs. Making the output unit's binding an injected object is a separate project and nothing here needs it.

### Phases

**L0: measure and decide.** Build Vibe and VibeiOS as they are with a `VibePro` app target that lists the same shared entries plus an empty `Vibe/Library/`. If that builds and `make test` passes, the fallback exists and the split can proceed at its own pace. Confirm Apple's libsqlite3 ships FTS5 on both deployment targets (`PRAGMA compile_options` lists `ENABLE_FTS5`). Measure a clean build of both apps for the before number.

**L1: the cuts, in the apps as they are.** The nine settings reads, the access-manager reach, the fourteen strings, Convert's move and the waveform views' resolved-theme properties, each a PR that leaves every test and the debug channel passing. No library target yet, so each PR is reviewable on its own and `main` never carries a half-split.

**L2: the targets.** `VibeAudio` then `VibeWaveform`, the app and test targets relinked, `-ObjC` on every app, `check-layout` taught the matrix, `analyze` over the libraries. Done when both apps and both test suites build from the libraries, `make test`, `make test-audio` and `make analyze CONFIG=Release` pass, and the clean build is no slower than L0's measurement.

**L3: the docs.** `Audio/AGENTS.md`, `WaveformUI/AGENTS.md`, `Tests/AGENTS.md` and the root say where the boundary is and what may not cross it.

## Part 2: the library

### What exists

More of a library already exists than the product name admits, and the catalog is a thin layer over it.

- **Tags are cached and keyed.** `AudioTrackMetadataCache` persists every parsed file under `NSURL+Hash.cacheKey` (size, mtime, path hash) through PINCache, with the 128px thumbnail and the display-art rendition beside it. A catalog does not parse files; it asks this cache, and the sweep machinery (`AudioTrackMetadataLoader`, its ranking, its foreground rule) scans a folder of 100,000 files today.
- **Folders are remembered.** `FolderAccessManager` (mac) and `SearchFolderStore` (iOS) hold security-scoped bookmarks across launches and resolve them without blocking main. A watched folder is one of these with a scan attached.
- **A walk exists.** `NSURLUtil`'s four-wide folder walk, with the CUE stand-in rule, is the enumerator.
- **Search exists on iOS.** `FileSearchIndex` walks granted trees into memory and matches names. The catalog replaces it with a query.
- **Playlist files exist.** `PlaylistFile` reads CUE and M3U and writes M3U. A stored playlist exports through it.

What does not exist: any field beyond title, artist, file type, bitrate, sample rate, duration, tagged BPM and tagged key (`AudioTrackMetadata.h`; `Playlist/AGENTS.md` says plainly that Vibe shows no album, genre or date for any file). Any persistent store other than defaults and PINCache. Any list the user keeps other than the one play queue. Any UI that is not the player window.

### What Vibe Pro adds

**The catalog**, one SQLite database in Application Support, through the system's `sqlite3.h` and nothing vendored. Tables: tracks (the file's path, bookmark, cache key, the tag fields, the curated fields), folders (watched roots, their bookmarks, last scan), playlists and playlist folders, playlist entries, and the rekordbox tables Part 3 adds (grids, markers, loops). FTS5 over title, artist, album, comment and filename. The catalog is a Foundation-only class in `Vibe/Library/`, tested host-less over a temp database as `DropboxMirrorTests` is over a temp root.

**The tag fields.** `AudioTrackMetadata` grows album, album artist, genre, year, track number, disc number, comment, composer, label and rating, parsed once by the TagLib code that already reads title and artist. The cache archive carries a version; an entry without the new fields is a miss, as an entry without the bands already is for the waveform. That is one bump to a shipped archive and it costs every user one re-parse, so it ships with Pro's first beta and not before.

**The scan.** A watched folder is walked and its files are enqueued into the existing metadata sweep. The catalog observes deliveries and writes rows. On the mac, `FSEvents` on each granted root picks up adds, removes and renames while the app runs; on iOS there is no watcher, so each foreground rescans roots whose directory mtimes moved. A removed file keeps its row, marked missing, so a playlist on an unmounted drive comes back when the drive does.

**The browser.** On the mac, a sidebar (Library, each stored playlist and folder, each watched folder, each rekordbox USB while mounted) beside a table with the catalog's columns, sortable, with the FTS field above it. The player window as it is today sits above or beside it as one window, with the playlist pane becoming the play queue. On iOS, the Playlist tab becomes Library with the same sections, and the Files tab stays as the way to add a folder. Both are new view controllers in `Vibe/Library/Mac/` and `Vibe/Library/iOS/`; the base app's shell classes are subclassed or composed, never edited with a product flag.

**Stored playlists versus the play queue.** `Playlist` keeps its name and its job: the ordered rows the player walks, with its one observer and its cursor rules. A stored playlist is a catalog row set; playing one replaces the queue through `replaceAllWithTracks:startingAtIndex:`; adding to one writes the catalog and leaves the queue alone. Nothing in `Playlist` learns about the catalog. Drag from the browser to the queue reuses the mac table's drop machinery (`PlaylistDragRules.h`).

**Curated fields.** Rating, color, comment, play count, last played and date added live in the catalog, never in the file. They display in the browser and the queue. Play count increments on `didStartPlaying:` after the first thirty seconds, in the shell, by the same tick that feeds `AppStats`.

**Later, each its own plan:** smart playlists (a stored query), tag writing through TagLib (the cache key moves with the file's mtime, and `invalidateMemoizedCacheKeys` already exists for the convert swap), duplicate finding, a missing-file relinker.

### Guarantees it touches

- **"A track is named on screen in one place."** Unchanged; the browser's title and artist columns read `displayTitle` and `displayArtist`.
- **"Tag-over-analysis precedence."** Unchanged in Part 2. Part 3 adds a rank above tag.
- **"A row shows the loading bar only while a transfer is running."** Unchanged; browser rows observe `CloudTransferRegistry` as queue rows do.
- **The equalizer rules** are the queue's and the browser does not draw one.

### Budget

New directory: `Vibe/Library/`, argued here: a catalog is a concern nothing owns today, and the complexity budget's "fit it into whatever already owns the concern" has no answer for it. New types: the catalog, the scan observer, the browser's view controllers and sidebar model on each platform. Expected around a dozen, and the request is made here rather than when the code is written. Removed or unified: iOS's `FileSearchIndex` (the catalog's FTS replaces it in Pro; Vibe keeps it), the Favorites store in Pro (a watched folder is a favorite that scans).

### Phases

**C0: the fields.** `AudioTrackMetadata` reads the new tags, the archive version moves, the parse benchmark (`make bench-components`) shows the cost. Vibe gains the fields too, hidden.

**C1: the catalog and the scan**, host-less tested, driven by the debug channel (`add_watched_folder`, `dump_catalog`), with no UI. Done when a 100,000-file tree scans into rows, the sweep's foreground rule still holds, and a relaunch shows the rows without touching a file.

**C2: the mac browser.** Sidebar, table, search, drag to the queue, play from a row. Done when the stress suite runs the mac app with a catalog of that size without a frame over 16 ms in the browser.

**C3: stored playlists, ratings, play counts.** Export as M3U.

**C4: the iOS browser.**

## Part 3: rekordbox

### What rekordbox's library is, and what Vibe Pro reads

rekordbox keeps its library in three forms, and they differ in whether reading them is documented, encrypted or merely reverse-engineered.

| Form | What it is | Reading it | Decision |
| --- | --- | --- | --- |
| `rekordbox.xml` | The bridge format rekordbox exports and imports from its Preferences (the Database or Bridge pane, by version). Documented by AlphaTheta on its developer page. Tracks with `Location`, tags, `AverageBpm`, `Tonality`, rating, color, comments, `DateAdded`, `PlayCount`; `TEMPO` beat grids; `POSITION_MARK` cues and loops; a playlist tree | Plain XML, official | **Read and write.** First |
| USB export: `PIONEER/rekordbox/export.pdb` plus `PIONEER/USBANLZ/*.DAT`, `.EXT`, `.2EX` | What a CDJ reads from a stick. DeviceSQL tables for tracks, playlists, artists, albums, keys, colors; the ANLZ files hold the beat grid (`PQTZ`), cues (`PCOB`, `PCO2`), waveforms and VBR seek tables | Unencrypted. Reverse-engineered and documented by Deep Symmetry (crate-digger's Kaitai definitions and its Export Structure Analysis) and by pyrekordbox | **Read.** Second. A plugged-in stick is a browsable, playable library with its grids and cues |
| `master.db` | rekordbox 6 and 7's live library in `~/Library/Pioneer/rekordbox/` | SQLCipher over SQLite with a static key embedded in the rekordbox application, which pyrekordbox extracts from the install at run time | **Out.** Shipping the key, or code that extracts it, in an App Store product is a question for counsel before it is one for engineering, and it needs a vendored SQLCipher. The XML bridge reads the same library with the user's consent |
| rekordbox 7 "Device Library Plus" | The newer stick format for the current players | Encrypted, one key for every stick | **Out**, as `master.db` is. The classic `export.pdb` is still written beside it for older players |

Writing a USB export is out too. CDJs reject a malformed `export.pdb` with no diagnostic, and the format is reverse-engineered. Vibe Pro writes `rekordbox.xml`, which rekordbox imports and then exports to the stick itself.

### What the data maps to

| rekordbox | Vibe Pro |
| --- | --- |
| `Location`, `Size` | The catalog row, matched as below |
| `Name`, `Artist`, `Album`, `Genre`, `Year`, `TrackNumber`, `Comments`, `Label`, `Remixer` | Catalog tag fields; the file's own tags win on conflict, since the catalog's are from the file |
| `Rating`, `Colour`, `DateAdded`, `PlayCount` | Curated fields |
| `AverageBpm`, `Tonality` | Curated tempo and key, the rank above the tag (below) |
| `TEMPO` (`Inizio`, `Bpm`, `Metro`, `Battito`), `PQTZ` | A beat grid: anchored, possibly multi-segment. Skips snap to it instead of to bars counted from zero |
| `POSITION_MARK` type 0 `Num` 0 to 7, `PCOB`/`PCO2` hot cues | Hot cues: markers on the waveform, keys 1 to 8 jump through `play:atPosition:` |
| `POSITION_MARK` type 0 `Num` -1, memory cues | Memory cues: markers, the skip keys walk them when the grid is absent |
| `POSITION_MARK` type 4, loop cues | Loops: a region the voice repeats |
| rekordbox's own waveforms (`PWAV`, `PWV3`, `PWV5`) | Ignored. Vibe's waveform system is the better one and already keyed per file |
| Playlists, playlist folders, `KeyType` 0 by track ID or 1 by location | Stored playlists and folders in the catalog |

**Matching a track** is the two-tier rule the iOS restore already uses: the standardized path first, then filename plus size, since a stick's or a drive's mount point differs between machines. An unmatched track keeps its row, marked missing, so a playlist imports whole and resolves as drives mount.

**TRAP, from the import side:** `TRACK` is not self-closing when it carries `TEMPO` or `POSITION_MARK` children, and a parser that only handles the self-closing form drops every grid and cue. Engine DJ users report hot cues landing about 0.025 s off the grid on XML import; the offset equals the grid's `Inizio`, which suggests cue times are absolute file seconds and grid starts are too, and the importer must not re-anchor one to the other. Verify against a real export in R0.

### The engine and waveform work the data needs

Without these, rekordbox support is playlists and ratings, which is still worth shipping first.

- **Markers on the waveform.** Both views gain a `markers` array (position, kind, color, label) drawn in the layer the mac view already draws the playhead line in and the scrubber draws its center line in. The renderers never see them; `WaveformUI/AGENTS.md`'s playhead-line rule is the precedent. Size S.
- **Grid-aligned skips.** `TransportMath.h` takes an anchor and a segment list instead of a tempo alone. The skip arithmetic is tested; this extends the tests. Size S.
- **Hot-cue jump.** `play:atPosition:` exists; the keys and the iOS pad are shell work. Size S.
- **Loops.** The voice reads to the loop's end and seeks to its start on its own decode queue, which is what a cue row's `endFrameInFile` already bounds a read at. The ring carries contiguous audio across the seek, so the loop is seamless by construction, as a gapless successor is. A loop's exit is a ramp back to the read position. Bit-perfect output needs no exception: the samples are the file's. Size M, and it is `AudioVoiceBus`'s, under its threading rules and the render suite. A loop out of the engine's loop is what makes a looped track sample-identical to the file in `make test-audio`.
- **The precedence rank.** `AudioTrack.bpm` and `.key` become curated, then tag, then analysis. The curated pair is set on the row at mint time, as a cue row's title and window are, so the one home stays one home and no shell computes it. The root guarantee's bullet changes one sentence.

### Budget

New files: an XML reader and writer and a `.pdb`/ANLZ reader in `Vibe/Library/Rekordbox/`, with their `*Rules.h` for the decoding decisions (the Location URL encoding, the `KeyType` resolution, the ANLZ tag walk), all host-less tested over fixtures. New types: those three readers and the grid and marker records. Removed or unified: nothing, and that is expected: this part adds a format family, not a mechanism.

### Phases

**R0: fixtures.** A real `rekordbox.xml` from rekordbox 7 and a real stick from rekordbox 7 with the classic export on it, with the cue-offset question answered against the CDJ's own display. Nothing is built until these are in hand.

**R1: XML in and out**, playlists and curated fields only. Done when a rekordbox library round-trips through Vibe Pro and rekordbox reimports Vibe Pro's XML without complaint.

**R2: markers, grid-aligned skips, hot cues.** The engine and waveform work above, minus loops.

**R3: the USB export.** A mounted stick appears in the sidebar. Its playlists play from the stick with their grids and cues.

**R4: loops.**

## Part 4: streaming

"Streaming" means two things, and only one of them is engineering.

### Files that arrive slowly

This is `streaming-any-source.md`, which is already planned in detail: one wait in `AudioFileHandle`, many writers behind it, with Dropbox's download the one writer built today. Its phases stand as written, and Pro's additions are more writers:

- **A media server.** Subsonic, Navidrome, Jellyfin and Plex serve the user's own files over HTTP with range requests, and WebDAV is a mount. Each is a writer that serves the wanted range, fetches ahead of the reader and never completes, which is row three of that plan's writer table exactly. Its catalog is the server's: the server's listing becomes catalog rows with no bookmark, marked remote, and the metadata parse reads by range through `VibeRangedStream` as the Dropbox mirror's does. This is the streaming that fits a custom engine, because the bytes are a file.
- **Dropbox on the mac**, through the HTTP client the iOS app already has. The client and mirror are Foundation-only and already compile into the mac test suite, so the port is the shell's browser and the mac's grant model.
- **Google Drive**, per `ios-google-drive.md`, once its restricted-scope question is answered.

Size: the shared plan's phases 0 to 3 are L on their own. A media-server source is M on top.

### Streaming services

TIDAL, Beatport Streaming, Beatsource, SoundCloud Go+ and Apple Music all reach DJ software through partner agreements, not public SDKs. TIDAL has required its DJ Extension plan for use through djay since May 2024, and the same plan gates the other DJ apps. Beatport's LINK and Streaming reach Serato, rekordbox, djay and the hardware makers through partnerships. SoundCloud grants API access by application. Apple Music plays only through MusicKit's own player, which hands out no PCM, so nothing it plays can reach the voice bus, the waveform, the FX or the level meter.

The engine is built to own every sample it plays. A DRM stream is by definition one it cannot own. So streaming services are out of this scope until a partner agreement exists, and when one does, the work is a writer behind the same wait if the partner delivers bytes, or a second player beside the engine if it delivers only a playback session. The second shape loses every feature the product is sold on and should be refused.

The catalog's "remote, no bookmark" row kind in Part 4's first half is the only hook left for it, and it costs nothing.

## Packaging

**Two products, one repository.** `VibePro` and `VibeProiOS` are two more app targets with their own bundle identifier, sharing the `vibe-version` group so a release bumps one number. Universal purchase across mac and iOS as Vibe has today. The release scripts take a target name; `vibe-release`'s two paths are unchanged in kind.

**The shell is a superset by directory.** `Vibe/Library/` holds everything Pro adds, with `Mac/` and `iOS/` halves. Where Pro's shell must differ from Vibe's (the window with a sidebar, the extra menus, the Library tab), a subclass in `Vibe/Library/` overrides the base class. No `VIBE_PRO` preprocessor flag anywhere, for the reason `#if DEBUG` is banned from shipping headers: a flag is a second product hiding inside the first's files.

**The strings catalog is shared.** Pro's keys join `VibeStrings.h` under a `library.*` and `rekordbox.*` prefix; `make strings` extracts them into the one catalog, and Vibe ships keys it never shows, which costs kilobytes.

**The sandbox holds.** Watched folders are bookmarks, a stick is a folder the user grants once, an XML file comes through the open panel. Nothing here needs the unsandboxed build `unsandboxed-direct-build.md` plans.

**Licensing holds.** Vibe is Apache 2.0, which permits a second product on it, closed or open. TagLib's MPL 1.1 election is unaffected by static linking into a second app. The notice file gains nothing. SQLite is public domain.

### Options weighed

- **One product with a paid unlock.** `Vibe/Library/` compiles into Vibe's targets and a receipt check shows or hides it. No new app targets, no release-script change, no library split needed for the product's sake. Roughly four weeks cheaper. Rejected here because the issue template, the App Store page and the README say Vibe has no library and no accounts, and because a free app carrying a catalog it hides is the shape the complexity budget calls two mechanisms splitting one job. If the maintainer prefers it, Part 1 still stands on its own merits and Parts 2 to 4 are unchanged.
- **A dynamic framework instead of static libraries.** It would let the widget extension load the waveform renderers without compiling them twice. It costs a bundle, embedding, launch-time loading, and strings that must name their bundle. The widget bakes two images. Compiling twice is cheaper.
- **A Swift package for the libraries.** SwiftPM builds C and ObjC targets, but per-file compiler flags, the ObjC++ boundary and the vendored tree's excludes are all awkward in it, and the repo's build is XcodeGen. Not worth a second build system.
- **Reading `master.db` behind a user's explicit folder grant.** The grant does not change what the key is or where it came from. Out until counsel says otherwise.
- **Core Data or a vendored ORM for the catalog.** `sqlite3.h` with FTS5 is a few hundred lines of plain C calls, tested host-less, and nothing else in the repository would use the heavier thing.
- **Streaming services through a web view or a second player.** Refused above.

## Risks

- **The cache archive bump** (C0) re-parses every user's library once. It ships inside a beta and is announced.
- **The precedence change** (R2) is a change to a root guarantee. It is one sentence, but every stamp site is re-read when it lands.
- **The loop** is the one engine change under the render's rules. It gets the render suite's treatment and a soak before it ships.
- **Format drift.** rekordbox's XML is official. The stick format is not. R3 pins a rekordbox version and re-runs its fixtures on each release, as the streaming plan re-runs its provider probe.
- **The scan's cost on iOS** with no watcher. A foreground rescan of mtimes over bookmarked roots is provider IPC. C1 measures it on a device before C4 commits to it.

## Sources

- rekordbox for Developers (the XML specification): https://rekordbox.com/en/support/developer/
- pyrekordbox, XML format notes: https://pyrekordbox.readthedocs.io/en/latest/formats/xml.html
- pyrekordbox, analysis files: https://pyrekordbox.readthedocs.io/en/latest/formats/anlz.html
- pyrekordbox, quickstart and `master.db` handling: https://pyrekordbox.readthedocs.io/en/latest/quickstart.html
- pyrekordbox, Device Library Plus: https://pyrekordbox.readthedocs.io/en/latest/formats/devicelib_plus.html
- Deep Symmetry crate-digger (`export.pdb` and ANLZ structures): https://github.com/Deep-Symmetry/crate-digger
- Engine DJ forum, rekordbox XML hot-cue offset: https://community.enginedj.com/t/rekordbox-import-hotcue-offset/46395
- Algoriddim, TIDAL's DJ Extension requirement: https://help.algoriddim.com/hc/en-us/articles/360012493060-What-streaming-service-options-are-available-in-djay
- AlphaTheta, StreamingDirectPlay for Beatport Streaming and TIDAL: https://alphatheta.com/en/information/opus-quad-omnis-duo-streamingdirectplay-support/

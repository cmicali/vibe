# Playlist

`AudioTrack` (the row) and `AudioAnalysisObservers` are shared with iOS. The model, `Playlist`, is vibe-libs' `media/PlayQueue`. The CUE and M3U readers and the M3U writer, `PlaylistFile`, and the record they return, `PlaylistEntry`, are vibe-libs' `media/Playlists`. The folder walk, `FolderWalk`, is vibe-libs' `media/FolderScan`. Each piece's `AGENTS.md` holds its rules. **`Mac/` is the `NSTableView` half and the last-playlist store, and has its own `AGENTS.md`.** The iOS list is `Vibe/iOS/PlaylistViewController`.

## The row

**`AudioTrack` is one row: a file whole, or a cue sheet's window of one.** It holds the row's installed metadata, its analyzed tempo and key, and the sheet's names. `bpm` and `key` are the one home of the rule that tags beat analysis. `displayTitle` and `displayArtist` are the one place a track is named (root `AGENTS.md`).

**It adopts `VibePlayableItem` (vibe-libs' `audio/AudioTypes`), which is all the player and the caches read of it.** That is its URL, its window in CD frames, `sourceKey` and `cacheKey`. `sourceKey` is fixed at init, so a per-tick comparison allocates nothing. `cacheKey` is memoized and stamped with `NSURL.cacheKeyGeneration`, so a download that installs another version retires every memo at once. The window's arithmetic is `CueWindowMath.h`, in the same piece, which the CUE reader shares.

**It also adopts `AudioTrackMetadataHolder` (vibe-libs' `media/Metadata`), which extends the playable item.** The metadata loader installs its results through it. That is the installed metadata, the install that happens only while the row has no answer from the same version, and the delivery that runs only while that answer is still installed. The check and the store share the row's monitor. **TRAP: the player's `id<VibePlayableItem>` needs an explicit cast to become an `AudioTrack *`.** clang converts it implicitly only when the playable item inherits every protocol the class adopts. It does not inherit the holder (`AudioTrack.h`).

**Rows are made from entries in one place.** The walk and the readers return `PlaylistEntry` records: a file whole, or a CUE sheet's window of one with the sheet's names. `AudioTrack rowsForEntries:` makes a fresh row of each. `entriesForRows:` goes the other way for the writer. It adds each row's duration and display names, which the `#EXTINF` line takes. Only `AudioTrack` names both types, so the walk and `PlaylistFile` never name the row.

**The player never writes the row, so each shell stores its settled length.** `duration` takes the player's at `didStartPlaying:`, at `didAutoAdvanceFromTrack:toTrack:` and at `didSettleDurationOfTrack:` (`adoptSettledDurationOfTrack:`, in each shell's `+PlayerEvents`). It is written only while the player still sounds that row, since the player's duration is the sounding track's. Until then a windowed row answers its window, and a whole file its metadata's length.

## Tempo and key

The analyzers are vibe-libs' `audio/Analysis`, which has its own `AGENTS.md`. This section is what Vibe adds.

**The app joins the tempo and key analyzers to the waveform decode** (`AudioAnalysisObservers.h`). It lives here because the row is where tempo and key land. Analysis and the waveform loader do not know each other. Each analyzer is its own sink, through a category. Each has one observer. Their identifiers are `bpm` and `key`, and each result is an `NSNumber`. A change to what either computes takes a new identifier. Every entry analyzed the old way then misses and is analyzed again. The same file reads a tempo or a key back out of a decode's results. A bad one reads as unknown.

**Tempo runs on both platforms, and key on macOS only.** A decode runs an analyzer only when its `VibeWaveformAnalysisProvider` lists the observer. The mac's provider reads `analyzeBPM` and `analyzeKey`. The iOS card's lists only the tempo, under `analyzeBPM`. So on iOS `AudioTrack.detectedKey` stays unset, and a track's `key` is its tag's. `analyzeBPM` is shared in `AppSettings`, and `analyzeKey` is macOS-only.

**`analyzeBPM` defaults on.** On iOS the detected tempo also drives the FX pad's delay taps (`iOS/Player/AGENTS.md`). Off, the waveform caches with no tempo. A file scanned while it was off is analyzed again only when a request that lists the tempo's observer misses its entry (`Audio/Waveform/AGENTS.md`). **`analyzeKey` defaults off.** Exact-match accuracy on real dance music is around half, which is not worth showing unasked. A tagged tempo or key always displays.

**Results land on every row sounding the window.** They travel in `CodableAudioWaveform.results` and arrive through `audioWaveformCache:didLoadResults:forTrack:`. They land in the transient `AudioTrack.detectedBPM` and `.detectedKey`. A cue row is analyzed over its own window, so a mix gets a tempo and key per track. A receiver stamps every row whose `sourceKey` is the delivered track's (`Playlist.stampTracksSounding:usingBlock:`), never just the current one (root `AGENTS.md`, async deliveries).

**A whole file's tag beats analysis, and a cue row's never does** (root `AGENTS.md`). `AudioTrack.rowTagMetadata` is nil for a windowed row. `AudioTrackMetadata.bpm` reads TagLib's PropertyMap "BPM": ID3 TBPM, MP4 tmpo, and Vorbis BPM. `AudioTrackMetadata.key` reads "INITIALKEY": ID3 TKEY and Vorbis or FLAC INITIALKEY. It falls back to the MP4 freeform atom "initialkey". It is parsed through `VibeMusicalKeyFromString`.

**The loader pipelines the decode and the analysis.** Analysis adds wall time only when it outlasts the decode it overlaps. The debug verbs `scan_bpm` and `scan_key` report the split between `streamSeconds` and `finishSeconds`, in Debug, where `-O0` inflates everything but vDSP. For a quick signal with no app and no dataset, use the `vibe-debug` skill's `scan-bpm.sh` and `scan-key.sh` on the generated `bpm-*.wav` and `key-*.wav` loops. The `bpm-*.wav` loops double as the atonal case for key. Real accuracy is GiantSteps, through `scripts/analysis/validate-tempo.py` and `validate-key.py`. Re-run both after any analyzer change.

## The model

The model is vibe-libs' `media/PlayQueue`. Its `AGENTS.md` holds the rules a caller is checked against: identity, the two indexes, the edits and their cursor, repeat, shuffle, and the open's start row. This section is what Vibe adds.

**Vibe's entries are `AudioTrack` rows.** Both shells make the model with `initWithURLKey:sourceKey:` and pass `AudioTrack.url` and `AudioTrack.sourceKey`. Both declare `Playlist<AudioTrack *>`. Callers mint a fresh `AudioTrack` per row: a file whole, or a cue sheet's window of one. Recreating rows from URLs would throw away installed metadata and artwork. The convert swap makes each replacement with `AudioTrack replacementAtURL:` (`Mac/MainWindow/Convert/AGENTS.md`).

**Each shell pushes the modes in from `AppSettings`.** The model reads no setting. `RepeatMode.h` holds only the enum, so the modes' stored identifiers are in `AppSettings.h`. The identifier-to-enum rules are in `SettingsRules.h`. A writer of Pause, repeat or shuffle must push and re-park (root `AGENTS.md`).

**The model does not touch the player.** On macOS the transition belongs to `MainPlayerController`'s removal funnel (`Mac/MainWindow/AGENTS.md`). A move's successor re-park is `playlistOrderDidChangeHandler`. The mac shell stamps its undo registrations with `structureGeneration`. `Mac/PlaylistDragRules.h` turns AppKit's insertion slots into the final positions a move takes. iOS has no remove or reorder UI (`Vibe/iOS/AGENTS.md`). On iOS, `PlaybackController` fans the model's events out to its views.

## The folder walk

The walk is vibe-libs' `media/FolderScan`. Its `AGENTS.md` holds its rules: the handlers, the order parameter, links, one file's entries, and a sheet's claims in a walk. This section is what Vibe adds.

**Vibe makes its rows from the walk's entries** (The row, above). `expandAndFilterList:sortedBy:completion:` completes on its worker, so the caller makes its rows there and then goes to main.

**The mac installs the walk's handlers at launch** (`AppDelegate`). iOS installs none.
- The playlist folder grant is `Mac/App/`'s `FolderAccessManager+GrantPanel`.
- The walked-file rank is folder art's cover rank (`FolderArtRules.h`).
- The walked folders and a bulk open's loose folders go to the folder-art resolver, which then pays for no listing of its own (vibe-libs' `media/Metadata`, Folder art).

**Each shell passes the folder-open order** (root `AGENTS.md`). The piece's `FolderOpenSort.h` holds only the enum. The orders' stored identifiers are in `AppSettings.h`. The identifier-to-enum rules and the display names are in `SettingsRules.h`. Settings calls the as-received order "Unsorted".

## Playlist files (.cue, .m3u, .m3u8)

The readers and the writer are vibe-libs' `media/Playlists`. Its `AGENTS.md` holds the resolution rungs, the CUE and embedded-sheet rules, the writer's directives, and the encoding and naming traps. This section is what Vibe adds.

The walk expands an opened playlist file in place, and a CUE sheet in a walk claims its files (vibe-libs' `media/FolderScan/AGENTS.md`). An entry readable nowhere still yields its primary candidate, which is what raises the folder grant (`Mac/App/AGENTS.md`, Sandbox grants).

The app hands the writer its rows through `AudioTrack entriesForRows:`, and makes rows of what the readers return through `rowsForEntries:` (The row, above). The session save and restore are the mac's `PlaylistFile+Session` (`Mac/AGENTS.md`). It restores the mirror on main at launch through `entriesInM3UData:`, which probes nothing and raises no grant panel. That is why a cue row's `#VIBE-CUE:` line carries its whole window and names. macOS reaches the writer through File > Save Playlist… and the quit-time mirror (`Mac/MainWindow/AGENTS.md`). iOS does not call it.

## Where opens come from

`Mac/App/AGENTS.md` owns the open funnel. This directory only receives its result through `PlaylistController`'s `loadTracks:selectingIndex:` and `append:`. On iOS an append lands through `PlaybackController`'s `folderSession:didAppendTracks:`.

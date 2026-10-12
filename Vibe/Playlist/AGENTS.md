# Playlist

`Playlist` (the model), `FolderWalk` (the disk walk) and `PlaylistFile` (the CUE and M3U readers and the M3U writer) are shared with iOS. All three are tested. **`Mac/` is the `NSTableView` half and the last-playlist store, and has its own `AGENTS.md`.** The iOS list is `Vibe/iOS/PlaylistViewController`.

## The model

`Playlist.h` states each method's contract. This section holds the rules a caller is checked against.

**A row's identity is the object.** Callers mint a fresh `AudioTrack` per row: a file whole, or a cue sheet's window of one. Recreating rows from URLs would throw away installed metadata and artwork and defeat every identity check. The convert swap mints a fresh object for the same reason (`Mac/MainWindow/Convert/AGENTS.md`).

**The model keeps two indexes.** A track-to-row map keeps `getIndexForTrack:` O(1) for the metadata sweep. A URL-to-rows index serves `indexesOfTracksWithURL:`, `stampTracksSounding:usingBlock:` and the convert swap. The URL index holds row sets because one file can sit in several rows. A delivery stamps every row of that file and window, so a duplicate row is never stranded.

- `replaceAllWithTracks:startingAtIndex:` and `appendTracks:` move no existing row, so they update both indexes incrementally.
- `removeTracksAtIndexes:`, its inverse `insertTracks:atIndexes:` and `moveTracksAtIndexes:toIndexes:` move rows. They renumber both indexes from the first row they move (`unindexRowsFrom:`, then `indexRowsFrom:`). All three take index sets. A single row is the one-index case, so there is no single-row path to drift.
- The cursor keeps naming the same object through every edit. A removed current row lands on `forwardTrackAfterRemovingTracksAtIndexes:`'s answer, else on the new last row. Insert clamps a past-the-end index, so an undo after later edits still restores the row.
- A move is set-to-set. Both sets are FINAL row positions, never AppKit insertion slots, which `Mac/PlaylistDragRules.h` converts. A move is its own inverse with the sets swapped.
- `structureGeneration` changes on a replacement or a clear. The mac shell stamps undo registrations with it.
- `advanceFromTrack:toTrack:` adopts a gapless boundary only while both exact objects still name the current row and its `trackEndSuccessor`.

**The model does not touch the player.** Removing the current row through it alone leaves the player sounding a track the playlist no longer contains. On macOS the transition belongs to `MainPlayerController`'s removal funnel (`Mac/MainWindow/AGENTS.md`). A move is transport-safe because the current object survives. Its successor re-park is still the shell's (`playlistOrderDidChangeHandler`). iOS has no remove or reorder UI (`Vibe/iOS/AGENTS.md`).

**There is one observer slot, and one structural edit sends one event.** A remove, insert or move does not also fire `currentIndexDidChangeFromIndex:`. Two callbacks would make the mac table reconcile one edit twice. On iOS, `PlaybackController` fans the events out to its views.

### Repeat and shuffle

**The model is the one home of "what comes next".** Each shell pushes the modes in from `AppSettings`. The model reads no setting, which is why `RepeatMode.h` is in `Common/`. There are two answers, because under Repeat One a skip and a track end differ:

- **`nextTrack`** is where Next lands: the next row, or under shuffle the next entry of the play order. It wraps under Repeat All and is nil at the boundary. `hasNextTrack` is its presence.
- **`trackEndSuccessor`** is what follows a track that plays out. It is nil under `pauseAtTrackEnd`, the current track under Repeat One, and `nextTrack` otherwise. `advanceAtTrackEnd` moves to it, and moves nothing when it is nil.

Previous never wraps.

**Shuffle is a play order of row objects walked by a cursor.** Entries before the cursor are played, the cursor is the current row, and entries after it are unplayed. The rows themselves never reorder. Because the order holds objects, a move needs nothing, and a remove or insert only drops or adds its own entries. A **manual pick** (`setCurrentIndex:` from outside next and previous) swaps the picked row into the next slot, or moves a played one out of the history. Nothing else repeats. Appends and an undo's inserts join the unplayed part at random. A removal never wraps.

Under Repeat All the next cycle is a fresh shuffle. Its first entry is never the track that just ended (the seam guard). It is made on first ask and kept, so the successor a gapless splice armed is the one Next lands on. Any edit to the order drops it, except the convert swap, which swaps its entry. `randomBelow` is injectable, so `PlaylistRepeatAndShuffleTests` walks seeded orders.

**TRAP: an open passes its start row to `replaceAllWithTracks:startingAtIndex:`. It never sets `currentIndex` after.** Under shuffle that set is a manual pick, which marks the order's random first row played without it ever sounding. `NSNotFound` lets the model choose: row 0, or under shuffle the order's random first.

## FolderWalk is the disk walk, and it stays ignorant on purpose

`FolderWalk` expands whatever the user opened (a file, a folder, a playlist file) into an ordered list of rows. A row is an `AudioTrack`: a file whole, or a CUE sheet's window of one (The model, above). It runs on background workers, never the main thread. **It calls no one. What it discovers is reported through handler blocks the app installs at launch.**
- `setPlaylistFolderGrantHandler:`: the grant a playlist file's unreadable entries need (`Mac/App/`'s `FolderAccessManager+GrantPanel`).
- `setWalkedDirectoriesHandler:` and `setBulkOpenDirectoriesHandler:`: the folders it listed and the covers it saw. The folder-art resolver takes them rather than paying for its own I/O (`Audio/Metadata/`).

**Unset handlers mean the walk still works and throws the extra facts away.** That is what the tests install. A walk that called a singleton behind a setting, a grant and a modal panel could not be tested, and this one is, fuzz suite included. `FolderWalkInternal.h` exposes the synchronous expansion steps for those tests. Do not import it outside `FolderWalk.m`, those tests and the bench harness.

**The folder-open order is a parameter, not a setting read.** `expandAndFilterList:sortedBy:completion:` and `rowsInDirectory:sortedBy:` take a `VibeFolderOpenSort` (`Common/FolderOpenSort.h`). That header holds the enum and its stored identifiers. It is a header of its own because the walk may not import a setting. It lives in `Common/`, beside `RepeatMode.h`, because `AppSettings` imports it too. The identifier-to-enum rules are in `SettingsRules.h`. Each shell reads it on main with the rest of its open snapshot (root `AGENTS.md`). One open then cannot straddle a Settings change, and the walk stays testable with no defaults store. Newest-first prefetches `NSURLContentModificationDateKey` in the enumeration. Name breaks equal dates, as for a folder copied in one go. "Unsorted" is APFS hash order on a local volume, effectively random. It is meaningful only on a file provider, whose listing order is what the choice exists for. **TRAP: decorate the dates and names once, never read them in the comparator** (the file's `TRAP:` says why).

**A symbolic link to a folder is a folder, and the walk is the only thing that can say so.** **TRAP: `NSURLIsDirectoryKey` is lstat-shaped**, and `NSFileManager` neither accepts a link as a walk root (ENOTDIR) nor descends into one it meets. Left alone, a dragged `~/Music/NAS` link would end the open in the empty state. `VibeResolvedDirectoryPath` resolves with `realpath(3)`. `URLByResolvingSymlinksInPath` would not do, since it leaves a `/private` prefix as it found it. The walk keeps its own work list of roots. Each directory link becomes another root, held back until the current enumeration finishes, so it can be tested against everything that enumeration covered. **The answer is spelled as the target, not the link**, so the tracks and the walked-directories handler name one folder. A `covered` set of every directory passed through ends a link cycle. With `skipDescendants`, it also keeps a link into an already-listed subtree from listing it twice. A link to a file stays a file. A **dangling** link is dropped. The emptiness filter answers NO to anything it cannot stat, so that a sandbox denial reaches the real open. A broken `Song.mp3` link would otherwise become an unplayable row.

**Every file's rows are minted by `rowsForFile:`, the only place a walk reads an audio file's contents.** A FLAC of 100 MB or more, a whole album or mix, is opened for an embedded sheet (`PlaylistFile cueRowsEmbeddedInFLACAtURL:`). A cloud placeholder is not, since the read would download it. Neither is one a sidecar sheet claimed. The size comes prefetched with the walk's other resource keys, so the gate costs a network volume no stat per file. The emptiness filter uses that size too. The walk drops an empty file itself (a link by its target's stat), and `expandAndFilterList:` stats only the rows no walk listed. `rowsInDirectory:sortedBy:`, the iOS listing, judges its entries through the same function (`VibeListedFileIsEmpty`), dangling links included.

The playable extension set is `Common/PlayableExtensions`. The walk's filter and `PlaylistFile`'s entry recovery both read it, so neither can grow a format the other lacks.

**TRAP: a playlist entry that is a remote placeholder counts as readable before `access(2)` is asked.** Its mode denies its owner, and `access(2)` reads that as a sandbox denial. Asked the other way round, an M3U naming a placeholder raises a grant panel (`expandPlaylistFile:`).

## Playlist files (.cue, .m3u, .m3u8)

`PlaylistFile` turns a playlist file into rows. `PlaylistFile.m` holds the M3U reader and writer. `PlaylistFile+CUE.m` holds the CUE reader and the FLAC's embedded sheet. The two share the entry rungs and the name cleanup through `PlaylistFileInternal.h`. `FolderWalk` expands one in place when it is opened at top level. Inside a folder walk an M3U is dropped, since it would double every track the walk found. **A CUE sheet in a walk stands in for its files** (`FolderWalk rowsForWalk:`). Its rows take its sorted place, and the files it names are claimed. A claimed file neither loads whole nor is cut again by a later sheet. Without the claim, `Album.cue` beside `Album (UTF-8).cue` would list every track twice. On both platforms, sheet rows must name supported, nonempty files that were listed or are readable.

**Each entry resolves through fallback rungs.** The rungs are the named path, then its basename beside the playlist (for a Windows-absolute path), then both again under each playable extension (for a rip transcoded after the sheet was written). In a walk, every rung looks its candidate up in the walk's own listing before the disk (`knownFiles`, grouped by `knownFileKeyForPath:`). An entry readable nowhere still yields its primary candidate. That lets the caller tell a sandbox denial from a missing file, which is what raises the folder grant (`Mac/App/AGENTS.md`, Sandbox grants).

**TRAP: against a listing every rung answers in the listing's spelling, never its own.** The walk claims files by exact URL. The volume folds case and Unicode normalization, and NSURL decomposes what it is handed. A probe would find the listed `01 - Title.flac` under the sheet's `01 - title.flac`, and the file would also play whole beside its rows. `testEveryResolutionRungClaimsTheListedFileUnderEverySpelling` covers every rung.

**A CUE sheet reads as rows** (`cueRowsInText:sheetURL:resolvingFile:`, one parser with the resolution injected). Each kept AUDIO TRACK becomes one `AudioTrack`, a window of its FILE in CD frames, with the sheet's TITLE and PERFORMER. Only those two fields are read. Every file keeps all its audio. Its first row starts at frame 0, a pregap plays at the end of the row before it, and a FILE with no surviving track plays whole. The drop rules are in `PlaylistFile.h`. `testCueFuzzedMutationsKeepRowsPlayable` holds every window playable under mutation.

**A FLAC can carry its own sheet** (`cueRowsEmbeddedInFLACAtURL:`). It may be the `CUESHEET` tag's text or the binary CUESHEET block. The text wins, since only it has titles. The block is rewritten as text for the one parser, with sample offsets rounded to CD frames. The first FILE line maps to the FLAC itself, and any other is dropped. Whether a file is worth opening for its sheet is `FolderWalk rowsForFile:`'s decision (above). A sheet beside the file outranks the one inside it.

An opened playlist that lists nothing playable adds no rows. A sheet naming an image Vibe does not play (APE, WavPack) lists nothing. An M3U gives file references only, and `#EXTINF` is ignored. The exception is the cue rows Vibe wrote into it (below).

These files come from other people's software, so the next two traps are load-bearing.

**TRAP: BOM-less UTF-16 must be decided *before* UTF-8 is tried.** A UTF-16 sheet of ASCII names has no byte above 0x7F. It decodes as UTF-8 *successfully*, with a NUL between every character, and the playlist opens empty. The order is BOM'd UTF-16, BOM-less UTF-16 signature, UTF-8, NUL-based UTF-16 fallback, CP1252, Latin-1. Latin-1 maps every byte, so a non-empty file always decodes.

**TRAP: a name may not reach `NSURL` carrying a NUL or an unpaired surrogate.** Both turn up in truncated and mis-encoded files. `NSURL` answers nil for such a component, and a nil candidate raises on the background expansion worker. `VibeStrippedOfUnpathableCharacters` drops them while the name is still a string. A `%00` in a `file://` M3U entry is dropped before `NSURL` parses it, because `.path` decodes it to a NUL on older Foundation and keeps it literal on macOS 26.

### Writing one

`writeM3UForTracks:relativeToDirectory:toURL:error:` is the only writer. It writes `m3uTextForTracks:relativeToDirectory:` atomically as UTF-8 without a BOM. A track under the target directory is written relative to it, and anything else is absolute. `commonDirectoryForTracks:` answers the folder that makes every entry relative.

**A cue row is written with two more directives before its path.** VLC's `#EXTVLCOPT:start-time=` and `stop-time=` let other players play the slice. `#VIBE-CUE:` carries the window and the names, which Vibe's readers turn back into exactly that row. The line carries everything rather than pointing at the sheet. The mirror is restored on main at launch, where reading a sheet on a cloud placeholder or a dead mount would hang the launch. A malformed line reads as a plain row.

**TRAP: every M3U reader trims whitespace, splits at newlines and skips a leading `#`.** So a name any of those would mangle goes out as a percent-encoded `file://` URL, which reads back whole. A backslash in a name does not round-trip, because the Windows-separator rule turns it into `/`.

`rowsInM3UData:` reads the app's own absolute output with no resolution rungs and nothing stat'd. So the session mirror comes back without a probe or a grant panel. The session save and restore are the mac's `PlaylistFile+Session` (`Mac/AGENTS.md`). macOS reaches the writer through File > Save Playlist… and the quit-time mirror (`Mac/MainWindow/AGENTS.md`). iOS does not call it.

## Where opens come from

`Mac/App/AGENTS.md` owns the open funnel. This directory only receives its result through `PlaylistController`'s `loadTracks:selectingIndex:` and `append:`. On iOS an append lands through `PlaybackController`'s `folderSession:didAppendTracks:`.

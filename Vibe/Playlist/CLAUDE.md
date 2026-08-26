# Playlist

`Playlist` (the model) and `PlaylistFile` (the CUE/M3U readers) are shared with iOS and sit at the top level, both tested. **`Mac/` is the `NSTableView` half and has its own `CLAUDE.md`**; the iOS target never names that subdirectory, and its list is `Vibe/iOS/LibraryViewController`.

## The model

`Playlist` keeps a track-to-row map **and** a URL-to-rows index. The URL index exists because the same file can sit in the playlist twice: analyzed BPM and key deliveries ask on every track start, and a duplicate row left pointing at a converted-away source would break the moment Delete Original trashes it.

- `replaceAllWithURLs:` replaces the list; `appendURLs:` extends it without touching playback or `currentIndex`. Neither moves an existing row, so both maintain the two indexes incrementally.
- `indexesOfTracksWithURL:` reaches every affected row at once; `replaceTrackAtIndex:withURL:` is the convert swap's landing point and maintains both maps, so a delivery for the departed file cannot stamp a row that no longer holds it.
- **`removeTracksAtIndexes:`, its inverse `insertTracks:atIndexes:` and `moveTracksAtIndexes:toIndex:` are the mutations that MOVE rows**, so they rebuild both indexes (`rebuildIndexes`) instead of patching them — every entry below an edit names the wrong row otherwise. O(n) is what `NSMutableArray`'s own edit already costs, and an explicit user gesture can afford it; recreating `AudioTrack`s from URLs could not, since it would throw away installed metadata and artwork and defeat every identity check. All three are batch-shaped and a single row is the one-index case, so there is no parallel single-row path to drift. The cursor keeps naming the same object throughout: removal subtracts the removed rows above it — which is also what lands a removed current row on the survivor that slid in, or the clamp's new last row — while insert and move resolve the captured current object through the rebuilt identity map, wherever the edit pushed it. Emptying the list resets it to 0; inserting into an empty list leaves it at 0 naming the first new row. Insert clamps a past-the-end index to the end — the undo of a removal can land after later edits have shortened the list, and it should restore the row as the last one rather than not at all. A move takes a FINAL row index, not an AppKit insertion slot; `Mac/PlaylistDragRules.h` owns that conversion, once.
- **The model does not touch the player.** Removing the *current* row through it alone would leave the player sounding a track the playlist no longer contains, so the calling shell owns that transition — on macOS `MainPlayerController`'s removal funnel (`Mac/MainWindow/CLAUDE.md`). A move is transport-safe here — the current object survives, so no play funnel is entered — but its successor re-park is still the shell's (`playlistOrderDidChangeHandler`). iOS exposes no remove or reorder UI, and any future one must add its coordinator first rather than calling the model directly.
- Observers get `playlistDidReplaceAllTracks:`, `didAppendTracksAtIndexes:`, `didReplaceTrackAtIndex:`, `didRemoveTracksAtIndexes:`, `didInsertTracksAtIndexes:`, `didMoveTracksFromIndexes:toIndex:` and `currentIndexDidChangeFromIndex:`. There is **one** observer slot — the iOS shell's ordinary fan-out to several views is `PlaybackController`'s job, while its removal and move methods stay no-ops until iOS has a transport-safe coordinator (`Vibe/iOS/CLAUDE.md`).
- **One structural edit sends one event.** Each structural event carries only what the table reconciliation consumes — the removed or landed index set, or a move's sources and destination — and deliberately does *not* also fire `currentIndexDidChangeFromIndex:`: two callbacks for one edit make the mac table reconcile against the same action twice and obscure the ordering.

See `Mac/MainWindow/CLAUDE.md` for why the swap mints a fresh `AudioTrack` rather than reassigning a `url`.

## Playlist files (.cue, .m3u, .m3u8)

`PlaylistFile` turns a sheet into an ordered list of file URLs. `NSURLUtil` expands one in place when it is opened at top level, and drops one found inside a folder walk, which would otherwise double every track. Only file references are read — CUE timing and `#EXTINF` metadata are ignored.

Each entry resolves through fallback rungs: the named path, its basename beside the playlist (which rescues a Windows-absolute-path entry), then both again under each alternate audio extension (which rescues a rip transcoded after the sheet was written). An entry readable nowhere still yields its primary candidate, so the caller can tell a sandbox denial from a missing file — that distinction is what raises the folder grant (`Mac/Settings/CLAUDE.md`).

These files come from other people's software, so two traps are load-bearing rather than defensive.

**TRAP: the encoding rungs are order-sensitive, and BOM-less UTF-16 must be decided *before* UTF-8 is tried, not after it fails.** A UTF-16 sheet of plain ASCII filenames carries no byte above 0x7F, so it decodes as UTF-8 *successfully*, into text with a NUL between every character — every line then matches nothing and the playlist opens empty. Only a non-ASCII filename makes that decode fail, which is why the after-the-fact byte-order heuristic cannot carry this alone. Order: BOM'd UTF-16 → BOM-less UTF-16 heuristic → UTF-8 → NUL-based UTF-16 fallback → CP1252 → Latin-1. Latin-1 is last and maps every byte, so a non-empty file always decodes to something: mojibake in one filename costs one entry, a nil text costs all of them.

**TRAP: a name may not reach `NSURL` carrying a NUL or an unpaired surrogate.** Both turn up in truncated and mis-encoded files, and a `%00` in a `file://` URL decodes into one. `URLByAppendingPathComponent:` and `fileURLWithPath:` answer *nil* for such a component, and a nil candidate raised an exception on a background expansion worker — a crash on opening a corrupted playlist. `StrippedOfUnpathableCharacters` drops them while the name is still a string, and the resolver treats a nil primary as "this entry has no URL" rather than trusting it.

## Where opens come from

`Mac/App/CLAUDE.md` owns the open funnel — Launch Services burst coalescing, out-of-order expansion results and supersession. This directory only receives the resulting `play:` / `append:`.

# Rekordbox USB sticks on iOS: scope

Researched 2026-10-08 against repository revision `1e8dfdb`. This is a scope, not an implementation. No stick was parsed and no device was driven. Behaviors that need a live probe are marked **probe**.

## Recommendation

**Read the legacy `export.pdb` database, not the encrypted OneLibrary one, and show it as one extra folder inside the stick in the Files tab.** Playback, metadata, waveforms and the open roads need no change for the first milestone. The work is one binary parser and one new kind of browser level.

Three decisions shape the scope:

1. **Which database.** Every rekordbox export since 6.8.1 writes both databases to the stick. The legacy one is unencrypted and fully documented. The OneLibrary one is SQLCipher-encrypted with a key reverse-engineered from the rekordbox binary. Reading only the legacy one costs nothing in coverage today and avoids a dependency and a legal exposure. The risk is a future rekordbox that stops writing it.
2. **How a playlist opens.** A tap on a rekordbox playlist can open its files as a plain multi-URL open, which persists one bookmark per track, or through an M3U the app writes into its own container, which persists one bookmark and carries the playlist's name. The M3U road is recommended.
3. **Whose names and tempo show.** The first milestone shows what the files' own tags say. Rekordbox's title, artist, tempo, key and rating live in the database and need row-level fields on `AudioTrack` to show. That is the second milestone.

## What a rekordbox stick holds

Rekordbox copies the audio to `/Contents/<Artist>/<Album>/<file>` and writes its databases under `/PIONEER/`.

| Path | What it is |
| --- | --- |
| `PIONEER/rekordbox/export.pdb` | The legacy "Device Library": a DeviceSQL database. Unencrypted, little-endian, fixed-size pages. Tracks, artists, albums, genres, labels, keys, colors, artwork paths, the playlist tree, playlist entries and histories. Documented by Deep Symmetry's Kaitai definition and read by crate-digger, rekordcrate and pyrekordbox. |
| `PIONEER/rekordbox/exportExt.pdb` | My Tags, written by rekordbox 6 and later. Same page format, two table types. Not needed. |
| `PIONEER/rekordbox/exportLibrary.db` | "Device Library Plus", renamed OneLibrary in 2025. A SQLite database encrypted with SQLCipher. Its schema mirrors the desktop `master.db`: `content`, `artist`, `album`, `playlist`, `playlist_content`, `cue`, `key` and so on. Read by the OPUS-QUAD, OMNIS-DUO, XDJ-AZ and CDJ-3000X. |
| `PIONEER/USBANLZ/P<nnn>/<hash>/ANLZ0000.DAT`, `.EXT`, `.2EX` | Per-track analysis. `.DAT` holds the path, the beat grid (`PQTZ`: beat number, tempo × 100, time in ms), memory and hot cues (`PCOB`) and the preview waveforms. `.EXT` holds extended cues with colors and comments, the detail waveforms and the phrase structure. The track row's `analyze_path` names the `.DAT`. |

**The legacy database is enough.** AlphaTheta's USB export guide says the two libraries coexist on one stick and the player model picks which it reads. Converting a Device Library to OneLibrary from rekordbox's device menu leaves the Device Library in place. The one gap is a stick made by a tool that writes only OneLibrary; nothing found does that today.

**The database format in one paragraph.** Page 0 is a header: page size, table count, then one 16-byte table entry per table naming its type and its first and last page. A table is a linked list of pages. A page is a 40-byte header, a heap of rows, and a row index built backward from the page's end in groups of 16 two-byte offsets with a presence bitmask per group. A row whose presence bit is clear is deleted and may hold garbage. Strings are a one-byte kind: `0x40` is long ASCII, `0x90` is long UTF-16LE, anything else is short ASCII with the length in the kind byte. A track row is 0x88 bytes of fixed fields (tempo as BPM × 100, duration in seconds, sample rate, bitrate, file size, rating, color, and the artist, album, genre, key, label and artwork ids) followed by 21 string offsets, among them the title, the filename, the `file_path` from the volume root, and the `analyze_path`. The playlist tree row carries a parent id, a sort order, a folder flag and a name. A playlist entry row is a position, a track id and a playlist id.

**Why not OneLibrary.** Three reasons, each sufficient:

- Vibe would vendor SQLCipher and a crypto backend. The project's rule is Apple frameworks plus the four audio libraries.
- The key is a single constant extracted from the rekordbox application and stored obfuscated. Shipping it in an App Store app is circumvention of a technical protection measure in the sense the DMCA and the EU directive use, whatever the merits. Community tools accept that exposure. A paid app on both App Stores should not.
- It buys nothing. The same stick carries the legacy database with the same tracks and playlists.

Mitigation for the risk: the parser is one class behind one interface. If a future export drops `export.pdb`, the decision is revisited with that fact in hand.

## What Vibe does with a stick today

A stick on an iPhone with USB-C, or on an iPad, appears in the Files app as a Location once it is FAT32 or exFAT. Vibe's **Add Folder…** grants its root. The browser then lists `Contents` and `PIONEER`, and `Contents/<Artist>/<Album>` browses by artist and album for free. Search walks it by filename. A folder plays in the folder's order. So the missing pieces are exactly two: the playlists, and the names, tempo, key and rating rekordbox assigned.

Two platform facts to **probe** before the spike is called done:

- A plain bookmark to a removable volume. `FolderSession` and `SearchFolderStore` persist plain bookmarks. A forum report says a bookmark to a mass-storage device resolved once after a replug and then not again. If that holds, a Location on a stick dies at the next unplug and the user re-adds it. The fix, if needed, is the stores' existing stale-bookmark re-mint on resolve.
- Opening a stick's file while the stick is pulled. The open fails as any unreadable file does. The restore keeps whatever resolves. Confirm neither hangs.

## Design

### The parser: `RekordboxExport`, one new type in `Playlist/`

One new file pair, argued on these terms: a binary page database is a whole format, `PlaylistFile.m` is already 950 lines of text readers, and the reader must be testable host-less. It is a reader beside the CUE and M3U readers, not a model.

- `+exportAtURL:` reads `export.pdb` whole into memory (a 10,000-track export is a few MB) and parses on the caller's queue. It never runs on main. Parsing is bounds-checked on every page index, row offset and string length, so a truncated or hostile file yields fewer rows, never a crash. `PlaylistFileTests`' fuzz pattern applies: mutate a fixture 2,000 times and require no crash and every surviving row to name a path.
- It reads six tables and ignores the rest: tracks, artists, albums, genres, keys, the playlist tree and playlist entries. Colors, labels, artwork paths, histories and `exportExt.pdb` are not read. Artwork is the files' own embedded art, which the metadata scan already shows.
- It answers the tree the browser draws: the playlist folders and playlists under a parent, in `sort_order`; the tracks of a playlist in `entry_index` order; the artists, albums, genres and keys with their tracks. Every track resolves to a file URL as the granted root plus `file_path`. The path is matched against the stick's own spelling the way cue entries are matched against a listing (`PlaylistFile.knownFileKeyForPath:`): FAT32 and exFAT fold case, and the database stores composed Unicode where the disk may answer decomposed.
- A parsed library is cached in memory per stick, keyed by the database's size and mtime, the same key the metadata cache uses. A re-export invalidates it. Nothing is persisted.
- The fixture is a real export of three or four short tracks made with rekordbox, committed under `Tests/`. A hand-built writer is more code than the parser and proves nothing about rekordbox. A rekordbox 5 export and a rekordbox 7 export should both be tried once, since the `first_page` of a table is often a placeholder with zero rows and the string kinds differ by version.

### The browser: one more kind of level

`BrowserViewController` lists folders, then playlists, then files, all `NSURL`s. A rekordbox level is the one place that changes. When a listing's directory holds `PIONEER/rekordbox/export.pdb`, the browser shows a **Rekordbox Library** row first among the folders. Tapping it pushes a level drawn from the parsed library instead of a listing. The level kinds are Playlists (the tree, folders then playlists), Artists, Albums, Genres and Keys, then the tracks of whichever node was tapped.

- **A track row is a file row.** It draws with `VibeApplyFileIcon`, the size from the database, and the equalizer when it is playing. A tap plays the file alone, the long press has Play in Folder and Add to Playlist, exactly the rules a listing's file row has. The road is `openFileURL:inFolder:` as today.
- **A playlist row plays its tracks in rekordbox's order**, through the play button and the tap, and Add appends them. The browser never walks `Contents` for this.
- Select, the filter field and the add sheet work as they do on a listing, since rows are rows. The sort menu is absent on a rekordbox level: the order is rekordbox's.
- The detection is one stat per listing of a directory and costs a Dropbox or iCloud folder nothing extra, since the listing is already in hand. The parse runs off main the first time the row is tapped, with the icon-slot spinner the browser already has for an opening row.
- Strings: about eight new `STR_BROWSER_REKORDBOX_*` keys, `make strings` after.

The library is held by the level that parsed it and handed down the stack. No singleton, no store.

### Opening a playlist: the M3U road

`FolderSession` persists one bookmark per top-level URL an open contributed. A 300-track playlist opened as 300 URLs mints 300 bookmarks at the landing and resolves them three at a time at the next launch. Browse Files… multi-select already does this, so it is not new, but a playlist is routinely that long.

Instead, a tap on a playlist writes an M3U with `PlaylistFile.writeM3UForTracks:relativeToDirectory:toURL:error:` into `Application Support/Rekordbox/<stick key>/<playlist id>.m3u8`, with absolute entries, and opens that file through `openURLs:openInPlace:`. This buys:

- One bookmark, to a container file that needs no scope. The entries resolve under the stick's Location grant, which `SearchFolderStore` holds for the session.
- The reader's existing resolution rungs, so a stick re-granted under a new mount path still resolves by basename.
- The writer's first iOS caller. Today it is macOS-only by lack of a caller, not by design.
- The `#EXTINF` lines carry rekordbox's title and artist for any other player that reads the file.

Costs: the Playlist tab's title reads "Playlist", since an M3U base is a single-file base with no folder and no star. Naming the tab after a playlist file's name is a one-line change in `refreshChrome` and worth making in the same pass. A stick re-exported with different playlist ids leaves stale files behind; the directory is swept by stick key on each parse.

The fallback, if the M3U base reads wrong in use, is the plain `openURLs:` road with no other change.

### Names, tempo and key from the database: second milestone

The files on a stick carry whatever tags they had in the collection, which usually includes the title and artist and usually excludes the tempo and key rekordbox analyzed. Showing rekordbox's values means a row that outranks its file's tags, which is the shape a cue row already has: `cueTitle` and `cuePerformer` are row names that beat the file's metadata, set once at minting.

- Names: a rekordbox row is minted through the cue-row initializer with a whole-file window and the database's title and artist. No new field. The `cue` prefix on those two fields then names the wrong thing, so the consolidating pass renames them to row names shared by both readers.
- Tempo and key: two new row fields, and `AudioTrack.bpm` and `.key`, the single home of the tag-over-analysis rule, gain one tier: the row's value, then the file's tag, then the analysis. The root `AGENTS.md` guarantee is rewritten to say so. `MusicalKey.h`'s `VibeMusicalKeyFromString` already reads the names rekordbox writes to its key table in either classical or Camelot form (**probe** the exact spellings on a real export).
- Rating and color have no surface in Vibe and are not shown.

This milestone needs an open road that takes minted rows rather than URLs, since `openURLs:` mints its own through `NSURLUtil.rowsForFile:`. The M3U road has that for free once the `#VIBE-CUE` directive, which already carries a title and performer per entry, is written for a whole-file window. The reader turns it back into exactly that row. Whether a sheet URL of nil reads back cleanly is a **probe**; if not, the directive grows a tempo and key field and loses the sheet field in the same change, since nothing shipped reads it from a stick.

### Analysis files: not in scope, and what they would unlock

Vibe computes its own waveforms and tempo, so the `.DAT` and `.EXT` files are not needed to play or draw. They would unlock two things later, each a separate decision:

- Rekordbox's beat grid as the tempo feed and the bar-accurate skip's grid, in place of Vibe's analysis. The grid is the DJ's edited truth and would be read through the same row-tier as the tempo above.
- Memory and hot cues. Vibe has no cue-point surface on either platform. A cue could become a seek target in the card, but that is a feature of its own.

### macOS

Nothing here is iOS-only except the browser. The parser is shared and the M3U the iOS app writes is an ordinary playlist file. A stick on the mac is `/Volumes/<name>`; File > Open on its root walks `Contents` today. A rekordbox playlist on the mac has no surface to appear in, since the mac has no browser. If wanted, a playlist file written from the database on open is the smallest road and reuses everything above.

## Complexity budget

- New files: `Playlist/RekordboxExport.h` and `.m`, plus `Tests/RekordboxExportTests.m` and one fixture export. New types: one. Everything else lands in `BrowserViewController.m` and `FolderSession.m`.
- Estimated lines: the parser about 500, the browser level about 300, the M3U road about 60, strings and docs about 60. Second milestone about 120, mostly the row fields and the precedence.
- Removed or unified: the M3U writer gains a caller on iOS and stops being a mac-only path. The cue-row name fields become the one row-name mechanism for two readers in the second milestone. Nothing is deleted, because the stick's folders already browse and play through the existing walk and the feature adds a second entrance to it rather than replacing one.

## Sequence and acceptance checks

1. **Spike, two to three days.** Parse a real export in a host-less test: every track resolves to a file that exists on the stick, every playlist lists its tracks in rekordbox's order, and 2,000 fuzzed mutations crash nothing. Then the browser level and the M3U road, on a device with a stick. Settle the two bookmark probes above.
2. **First milestone.** Browse playlists, artists, albums, genres and keys from the stick. Tap a track, play a playlist, add a playlist, Play in Folder. Names from the files' tags. `make test`, `make check-strings`, `make analyze CONFIG=Release`, and `check-layout-stability.sh` on the new level.
3. **Second milestone.** Rekordbox's names, tempo and key on rows, with the precedence rewritten in `AudioTrack` and the root guarantee. The FX delay taps then follow rekordbox's tempo.
4. **Not now.** OneLibrary, analysis files, My Tags, histories, the mac.

Acceptance for the first milestone: a stick exported from rekordbox 7 with a nested playlist folder, a non-ASCII artist name, a playlist of more than 200 tracks and one track whose file was deleted from `Contents` after export. The deleted track is skipped, the long playlist opens and restores at the next launch, the non-ASCII track plays, and pulling the stick mid-play stops that track without hanging the app.

## Sources

- [AlphaTheta USB export guide (OneLibrary and Device Library coexist)](https://cdn.rekordbox.com/files/20251021171528/USB_export_guide_en_251007.pdf)
- [AlphaTheta OneLibrary-compatible USB export guide](https://cdn.rekordbox.com/files/20260317132052/OneLibrary-Compatible-USB-Device-Export-.pdf)
- [AlphaTheta notice on which players read which library](https://alphatheta.com/en/information/important-notice-for-customers-using-usb-devices-with-our-dj-equipment/)
- [Deep Symmetry crate-digger: `rekordbox_pdb.ksy`](https://github.com/Deep-Symmetry/crate-digger) and its `rekordbox_anlz.ksy`
- [rekordcrate: Rust parser for the same exports](https://docs.rs/rekordcrate)
- [pyrekordbox: Device Library Plus format notes](https://pyrekordbox.readthedocs.io/en/latest/formats/devicelib_plus.html)
- [Community notes on `exportLibrary.db` encryption](https://gist.github.com/0xdevalias/b803476793b56f7c45e6361799168eb0)
- [Lexicon: Device Library Plus](https://www.lexicondj.com/blog/everything-you-need-to-know-about-device-library-plus-and-more)
- [Apple: providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
- [Apple forum: bookmark to a mass-storage device after replug](https://developer.apple.com/forums/thread/773373)

# Favorites, Search and the folder stores (iOS)

The shell is `../CLAUDE.md`.

## What the app can search

**There is no public API that searches the Files app** — no search hook on the picker or browser, and `NSFileProviderSearchQuery` is the extension's side. The app can only walk trees it holds, so scope is granted folder by folder.

**`PlaybackController.searchRoots` composes the scope, and nothing else does.** Transient: `FolderSession.searchRoots` — the base folder and every folder an Add brought in — whose grants cover the subtrees the flat listing never reaches, gone at the next open. A single added FILE is a scope, not a root, so it never appears here. Persistent: `SearchFolderStore.searchRoots` (the Settings list plus the app's own Documents directory, which needs no grant) and `FavoritesStore`'s resolved bookmarks. `FileSearchIndex` prunes nested and duplicate roots.

## SearchViewController

A `UISearchController` installed on its own `navigationItem`; `UISearchTab` hoists that field into the collapsed tab bar, so there is one search controller. It does not focus the field on appear.

**Two sections, deliberately unsynchronized.** The playlist half is a synchronous pass over `Playlist.tracks` on the keystroke's run-loop turn. The files half snapshots what the walk has delivered and matches on its own serial user-initiated queue; the latest query or batch wins, and only the latest answer reloads that section. The empty query lists the whole playlist and no files. A section with no rows draws no header, except a walk still running, which shows the header plus a "Searching files…" footer.

A playlist change re-*filters* — rows are indexes into a playlist that was just replaced, and the exclusion set and roots may have changed; `viewWillAppear` refreshes unconditionally. `RootViewController` supplies the material-surface fact: expanding the card cancels hidden file matching, and revealing Search runs one current pass rather than replaying every batch.

**A playlist row selects and stays; a file row opens** — its folder becomes the playlist with it selected, the same road every open takes.

**The table dismisses the keyboard on drag** (`OnDrag`, not `Interactive`, which tracks a field the scroll view contains; this field is in the tab bar). Otherwise nothing on the screen puts the keyboard away and the bottom of the list is unreachable. Picking a row resigns the field but keeps the query.

## FileSearchIndex

One streaming walk into memory, then a latest-wins filter per query off main.

- **The walk reads directory listings only** — never bytes or tags — at `QOS_CLASS_UTILITY` on its own serial queue, because a listing is the same provider IPC an open needs and the open outranks it (root `CLAUDE.md`). It starts on the search screen's **appearance**, never earlier, so the other tabs pay nothing.
- Batches land on main every 128 files or 200 ms; `buildGeneration` is stamped on the walk and checked per batch, so a root change drops the walk in flight. Queries snapshot the files, check the generation throughout, scan only the suffix appended since their last answer, and return at most 200 rows. The index caps at 20,000 files and logs when it stops.
- **A hit is named from its path alone** — filename over folder, `music.note` glyph, nothing stat'd or read. The folder name is matched too (`FileSearchRules.h`): on a music tree it is the album or artist.
- **A track the playlist lists is not offered twice**: the screen passes its playlist paths as the exclusion set, rebuilt per playlist change and tested before the string match.
- **`FileSearchRules.h` is the matching rule for both sections**, tested from the macOS suite, and holds `VibeSearchRootCoversPath`, the coverage decision the pruning and the Settings list's refusal both read. The one intended disagreement is the empty query: no constraint for the playlist, no match for a file.

## SearchFolderStore

The folders the user handed the app to search: persisted security-scoped bookmarks, each scope started at launch and held for the session. The iOS twin of the mac's `FolderAccessManager`. Its own `NSUserDefaults` key, not `AppSettings`.

- **A folder here is search scope and nothing else** — not a second way to open something; a hit already opens its folder.
- **Coverage is tested against the persistent roots and never the open folder.** A subfolder of a listed folder, or anything inside Documents, buys nothing and is refused with a word rather than silently. The open folder is transient, so refusing against it would drop a grant the user wants at the next open. A folder that covers existing rows replaces them; a restored folder some root now covers is dropped.
- **Bookmark work never blocks main, and one provider cannot head-of-line every root**: launch restoration resolves at most three concurrently and merges on main in original order; minting has its own serial queue and needs the scope open, so a stale bookmark is refreshed only after resolving. A replacing parent owns the narrower rows' scopes until its own mint lands; pending identities remember a removed parent so a late child cannot resurrect it.
- **Removing a row hides it immediately but defers `stopAccessingSecurityScopedResource`** until the playlist and every overlapping open release the grant object `FolderSession` was handed, so later metadata and waveform reads keep the access that made the playlist valid.
- **It posts `VibeSearchFoldersDidChangeNotification`; Settings and Search derive their rows from that one delivery.** Launch resolves can land while either screen is up, and a local animation beside the notification would mutate the table twice.
- `restorePersistedFolders` runs at launch beside restore-or-adopt, not as a third branch: it opens and plays nothing.
- The channel cannot drive the document picker, so `dump_search`, `add_search_folder` and `remove_search_folder` set up a scope for a test. **TRAP: a folder added through the channel is not security-scoped and survives only the session.**

## FavoritesStore and FavoritesViewController

Starred folders, name over containing folder. **Tapping a row is a pick**: the store resolves the bookmark off main and hands the URL to `openURLs:openInPlace:YES`, which is `FolderSession`'s open prologue. Nothing about opening is reimplemented.

**A row's secondary actions are Add to Playlist and Remove from Favorites**, and both are reached twice, since Apple's guidance is that a context menu is never the only road to an action: a long press gives Play / Add to Playlist / Remove from Favorites, a **leading** swipe gives Add, and the trailing swipe stays the legacy system Delete (`canEditRowAtIndexPath:` plus `commitEditingStyle:`, which UIKit draws and localizes itself — implementing a trailing configuration would take that over). **Every one of them goes through `openFavorite:appending:`**, so an Add resolves the bookmark, deselects and alerts on an unreachable folder exactly as a tap does; only the `appending:` flag differs. **An Add takes its `addRequestToken` before the resolve**, not after: the resolve is provider IPC, and an Add judged only when it finished captured whatever playlist the user had opened while waiting and appended to that one instead of being dropped (`../CLAUDE.md`). A replace needs no token — it bumps the generation itself on arrival, and the newest replace is meant to win. The token proves staleness and nothing else, so a Files Add made later but resolved sooner still lands first; both land, and only their order gives. Remove acts on the favorite's own path, never the row index, because the list can move while the menu is up.

**A favorite is a place to go, not a grant to hold**, which is why this store is smaller than `SearchFolderStore`:

- **Nothing resolves and no scope starts until a tap** — or until the search screen appears, the first moment the scope is worth paying for. Rows draw from the name and location recorded at star time, so favorites cost no provider I/O at launch and a signed-out provider still renders.
- **Nesting is allowed** — a parent and a child are two places to open — so identity is exact standardized-path equality; `VibeSearchRootCoversPath` would be the bug here.
- **A row is never added without its bookmark.** Minting needs the folder's scope open, which only `FolderSession` can promise, so the star fills when the bookmark lands. `addFolderURL:bookmark:` dedupes by path, which is also what makes re-starring a no-op. **There are two minters and they differ in one thing — where the hold comes from.** `bookmarkOpenFolderWithCompletion:` serves the OPEN folder and takes its hold from the session's scoped list, because the base can be a URL the session derived; `bookmarkFolderURL:completion:` serves a folder the session does not own — the Files tab starring a browser-picked one without opening it — which arrives already granted, so its scope is started directly. Both run off main and land on main, and both leave this store a recorder.
- **A nil resolve alerts and leaves the row**: a signed-out provider or an unmounted volume is temporary. A stale bookmark is re-minted on the resolve queue after resolving, and the scope stopped again at once — the adopt that follows starts its own.
- **A hit inside a starred folder is opened on a hold the SESSION owns**: `FolderSession.openFileFromSearchRoots:` asks `resolvedRootCoveringURL:` and starts its own scope, so unstarring the current playlist's folder drops only this store's scope and playback keeps reading.

`VibeFavoritesDidChangeNotification` drives three readers: this screen, the Playlist tab's star, and Search's roots. Removal — swipe here or tap the filled star there — lands on `removeFavoriteAtIndex:`. **An open that found no audio brings the Playlist tab forward** (`RootViewController.playbackDidOpenEmptyFolder:`), since only that tab's empty state says so; `PlaybackController` withholds the event while a good playlist is loaded.

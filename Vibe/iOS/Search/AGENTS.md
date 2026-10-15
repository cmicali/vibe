# Favorites and Search (iOS)

This directory holds the Favorites tab, the search screen, and the Favorites store (`FavoritesStore`). It also holds the search screen's two sources: the walk over granted folders (`FileSearchIndex`) and the Dropbox search (`DropboxSearch`).

The shell is `../AGENTS.md`.

## What the app can search

**No public API searches the Files app.** The picker and browser have no search hook, and `NSFileProviderSearchQuery` is the extension's side. The app can only walk trees it holds, so scope is granted folder by folder.

**`PlaybackController.searchRoots` composes the scope, and nothing else does.** The transient half is `FolderSession.searchRoots`: the base folder and every folder an Add brought in, gone at the next open. A single added file is a scope, not a root, so it never appears here. The persistent half is `LocationStore.searchRoots` and `FavoritesStore`'s resolved bookmarks. `LocationStore` (`../Files/AGENTS.md`) answers with the Files tab's Locations plus Documents, which needs no grant. `FileSearchIndex` prunes nested and duplicate roots, in both directions (the `TRAP:` in `FileSearchIndex.m`).

## SearchViewController

A `UISearchController` on its own `navigationItem`. `UISearchTab` hoists that field into the collapsed tab bar, so there is one search controller. It does not focus the field on appear.

**The scope bar is All, Playlist, Local and Dropbox (while linked)**, in the order the sections are drawn. An appearance with an empty field resets it to All, since a leftover scope made the next search look empty. **A query that every half in scope answered with nothing draws the system's No Results** (`refreshEmptyState`). The scope bar, which sections draw, and No Results are `FileSearchRules.h`'s. A half still asking, or a Dropbox failure, is not that.

**The sections are deliberately unsynchronized.** The playlist half is a synchronous pass over `Playlist.tracks` on the keystroke's turn. The files half snapshots what the walk has delivered and matches on its own serial queue. The latest query or batch wins, and only the latest answer reloads that section. The empty query lists the whole playlist and no files. A section with no rows draws no header, except a walk still running, which shows the header and a "Searching files…" footer.

A playlist change re-filters, because rows are indexes into a playlist that was just replaced. `viewWillAppear` refreshes unconditionally. `RootViewController` supplies the material-surface fact: expanding the card cancels hidden file matching, and revealing Search runs one current pass. **A metadata delivery re-matches the playlist half alone** (`refilterIfStale`, coalesced). It changes only what the playlist's rows say, and a full re-filter blanked and re-asked the other halves on every delivery of a scan.

**The Dropbox section asks Dropbox, not the disk.** The walk never sees the mirror, which holds only folders already listed. `files/search_v2` searches the linked app's authorized Dropbox scope (`DropboxMirror searchQuery:`). It returns at most 50 folders and supported files. The section's state and its requests are `DropboxSearch`, which the screen holds and reads. Its `changeHandler` reloads the section when an answer or its count of downloads lands. A query waits for a 0.3 s pause in typing. `_searchGeneration` moves on every new query and when the screen hides mid-search. It drops any answer to a query already typed past. An account change drops the answer in hand and any in flight (`dropboxAccountDidChange:`), since its paths would resolve against the new account. **Only a new query asks Dropbox.** The answer is kept against its query, and a re-filter for the same query only re-applies the playlist exclusion. While asking, the heading reads "Searching Dropbox…" with a spinner. After a failure it reads "Couldn't reach Dropbox.", which is how a failure differs from no results. A hit the mirror holds no bytes for carries `FileRow`'s `VibeNotDownloadedMark`. A hit already in the playlist is left out by its Dropbox path. **Opening a hit lists its folder into the mirror first** (`localURLForEntry:`), so the file it names exists as a placeholder.

**A playlist row selects and stays. A file row plays that file alone** (`openFileURL:inFolder:NO`). **A folder row opens in the Files tab**, as a folder does in the browser. A Dropbox hit that cannot be reached says so in an alert. The long press is the rule Recents shares (`VibeBrowserRowActionsFor`, `Files/BrowserRules.h`): Play, Play in Folder for a file, Add to Playlist, and Open Folder. Every hit takes one road, and whether the open becomes the session bookmark is `FolderSession`'s call. The menu captures the hit, not the row, since a late answer can reload the section while it is up.

**The table dismisses the keyboard on drag** (`OnDrag`, not `Interactive`, which tracks a field inside the scroll view; this field is in the tab bar). Otherwise nothing puts the keyboard away and the end of the list is unreachable. Picking a row resigns the field but keeps the query.

## FileSearchIndex

One streaming walk into memory, then a latest-wins filter per query off main.

- **The walk reads directory listings only**, never bytes or tags, at `QOS_CLASS_UTILITY` on its own serial queue. The utility queue gives it lower scheduling priority. A provider listing already in progress cannot be interrupted by a playback open. It starts when the search screen first appears, so the other tabs pay nothing.
- After accepting a file, the walk flushes when it reaches `kFlushBatchSize` or `kFlushInterval` has elapsed. A blocked directory listing can delay the next flush. `buildGeneration` is stamped on the walk and checked per batch, so a root change drops the walk in flight. A query snapshots the files, checks the generation throughout, scans only the suffix appended since its last answer, and returns at most `kMaxFileResults` rows. The index caps at `kMaxIndexedFiles` and logs when it stops.
- **A hit is named from its path alone**: filename over folder, the browser's file tile, nothing stat'd or read. The screen sorts each answer by name. The folder name is matched too, since on a music tree it is the album or artist.
- **A track the playlist lists is not offered twice.** The screen passes the playlist's paths as the exclusion set, tested before the string match.
- **`FileSearchRules.h` is the matching rule for both sections**, tested from the macOS suite. It also holds `VibeSearchRootCoversPath`, the coverage decision the pruning and the Locations list's refusal both read. The one intended disagreement is the empty query: no constraint for the playlist, no match for a file.

## FavoritesStore and FavoritesViewController

Starred folders, drawn as the Files tab draws a folder row (`FileRow`'s `vibeApplyFileIconForName:folder:art:` and `vibeApplyFileNameStyle`). **Play and Add go through `openFavorite:appending:`**, which resolves the bookmark off main, deselects, and alerts on an unreachable folder. A tap replaces through `PlaybackController`'s `confirmReplacing…` funnel with a replace token. An Add hands the folder to `addURLs:token:`. **A Dropbox favorite with no song directly inside opens in the Files tab** (`showDirectoryHandler`), where its subfolders are, after it is listed from Dropbox.

**Both tokens are taken before the resolve** (`addRequestToken`, `replaceRequestTokenOpening:`). The resolve is provider IPC, and a request judged only when it finishes would act on whatever the user opened while waiting (`../AGENTS.md`). The token proves staleness and nothing else, so a Files Add made later but resolved sooner still lands first.

**Add to Playlist and Remove from Favorites are each reached twice**, since a context menu should never be the only road to an action. The long press gives Play, Add to Playlist and Remove from Favorites. A leading swipe gives Add. The trailing swipe is the system Delete (`canEditRowAtIndexPath:` plus `commitEditingStyle:`), which UIKit draws and localizes itself. Remove acts on the favorite's own path, never the row index, because the list can move while the menu is up.

**A favorite is a place to go, not a grant to hold**, so this store is smaller than `LocationStore` (`../Files/AGENTS.md`):

- **Nothing resolves and no scope starts until a tap**, or until the search screen appears. Rows draw from the name and location recorded at star time, so favorites cost no provider I/O at launch.
- **Nesting is allowed**, so identity is exact standardized-path equality. `VibeSearchRootCoversPath` would be the bug here.
- **A row is never added without its bookmark.** Minting needs the folder's scope open, so the star fills when the bookmark lands. `addFolderURL:bookmark:` dedupes by path, which makes re-starring a no-op. **The two minters differ only in where the hold comes from.** `bookmarkOpenFolderWithCompletion:` serves the open folder and takes its hold from the session's scoped list, because the base can be a URL the session derived. `bookmarkFolderURL:completion:` serves a folder the session does not own (the Files tab starring a folder without opening it), which arrives already granted. Both run off main and land on main.
- **A nil resolve alerts and leaves the row**, since a signed-out provider or an unmounted volume is temporary. A tap refreshes a stale bookmark on the resolve queue and releases its temporary scope. Search keeps its resolved scope until removal and does not refresh the bookmark.
- **A hit inside a starred folder is opened on a hold the session owns.** `FolderSession.openURL:inFolder:` asks `resolvedRootCoveringURL:` and starts its own scope, so unstarring the playlist's folder does not stop playback reading.

`VibeFavoritesDidChangeNotification` drives three readers: this screen, the Playlist tab's star and Search's roots. Removal from either place lands on `removeFavoriteAtIndex:`. **An open that found no audio brings the Playlist tab forward** (`playbackDidOpenEmptyFolder:`), since only that tab's empty state says so. The event arrives whatever the playlist holds, and the root and the Playlist tab act on it only over an empty playlist.

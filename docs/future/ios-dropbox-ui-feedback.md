# iOS file browser and Dropbox: UI feedback

A usability audit of the UI that PR 132 introduced (the Files tab's browser, Recents, the add sheet, Dropbox browsing and search, and Settings › Files), with a recommended fix for each finding. Nothing here is decided; each recommendation is a proposal to accept, change, or drop.

**How it was audited.** The Debug build was driven in the iPhone simulator with real touches, in light and dark mode, against seeded local folders and a signed-in Dropbox account, on 2026-10-02.

**Not exercised.** iPad, Dynamic Type, VoiceOver, offline and error paths, the two system pickers, removing a Location, and a download slow enough to show the row loading bar. Findings marked *(from code)* were read, not seen.

**Severity.** *bug* is broken; *high* will confuse or mislead; *med* is friction; *low* is polish.

## Suggested order

1. Section A is fixed.
2. B1, B2, B4, C2, and D1 are small and remove most of the confusion.
3. C1 and E1 are the two design questions worth settling before release; several smaller items fall out of whichever way they go.

## A. Bugs (fixed)

All four are fixed in the working tree and were re-verified in the simulator.

| # | Finding | Fix made |
| --- | --- | --- |
| A1 | A playlist opened from the top level of Dropbox was titled with the raw account id (`dbid/AADMy…`). A favorite starred there would have saved the same name. | One rule names a folder everywhere: `+[SearchFolderStore displayNameForFolderURL:]`. The browser's titles and rows, the Playlist title, a favorite's name and location, and a recent's folder line all call it. It replaced the browser's private `titleForDirectory` and the store's `displayNameForFolderAtIndex:`. |
| A2 | Swiping a row to reveal Add to Playlist put the navigation bar into multi-select (a disabled Add button and a Done checkmark). | `BrowserViewController` tells a row swipe from the Edit button with `_swipingRow`, set and cleared in the table's begin and end editing callbacks. |
| A3 | Settings › Files showed a stale download size ("Zero KB" while songs downloaded behind it). | `DropboxMirror` posts `VibeDropboxDownloadsDidChangeNotification` after each fetch and its budget pass; the screen re-measures on it. |
| A4 | Tapping a Dropbox folder hit in Search could do nothing: it played the folder, which lands nothing when the songs are in subfolders, and a failed resolve was only logged. | A folder hit now opens in the Files tab, as a folder does in the browser. A hit that cannot be reached shows an alert. |

**Left open by these fixes.**

- A1: a recent recorded under an earlier app-container path still shows the raw folder name, because Recents derives its second line from the stored path. See D7.
- A4: Play on a folder from a long-press menu can still land nothing silently. See B2.

## B. Feedback and silent outcomes

| # | Sev | Finding | Recommended fix |
| --- | --- | --- | --- |
| B1 | high | Add to Playlist gives no confirmation in the Files tab. A full swipe on a folder added four tracks and nothing on screen changed. The context menu and multi-select Add are the same. | A success haptic plus a count badge on the Playlist tab (`UITab.badgeValue`) that clears when the tab is next shown. Both are system pieces; no toast view to build. |
| B2 | high | Adding or playing a folder that holds only subfolders does nothing, silently. Selecting "Albums" (subfolders only) plus one file added only the file. | Decide C4 first. If folders stay flat, an Add or Play that lands zero tracks shows a short alert: "No songs directly in Albums. Open it to choose a folder." If folders recurse, this finding disappears. |
| B3 | med | Adding something already in the playlist is skipped silently, and rows carry no mark for what is already there. | Report the real count through B1's badge, and when the count is zero say "Already in the playlist" rather than nothing. A per-row mark is not worth its cost. |
| B4 | high | Search with no results is a blank screen. In the Dropbox scope the "Searching Dropbox…" header just disappears. | `UIContentUnavailableConfiguration.searchConfiguration` when the query is non-empty, nothing is still searching, and every shown section is empty. |
| B5 | med | A Dropbox search failure looks the same as no results; the error is only logged. | Keep the Dropbox section with a footer, "Couldn't reach Dropbox", when the search fails. Reuse the existing string. |
| B6 | med | A failed Dropbox relist is invisible when the folder already has rows, so a stale listing looks current. *(from code)* | A table footer on the folder, "Couldn't reach Dropbox. Pull down to try again.", shown while `_refreshError` is set. The string exists. |
| B7 | med | The now-playing card shows no download progress. While a Dropbox track downloads it shows `--:--`, a flat line, and a Pause button. | Draw the transfer fraction the shell's monitor already has in the waveform's place, as the row's loading bar does. This is the surface the user is looking at after a tap. |
| B8 | low | "Searching Dropbox…" is a plain section header and reads as a label. | Put a small activity indicator in that header while searching. |

## C. Predictability

| # | Sev | Finding | Recommended fix |
| --- | --- | --- | --- |
| C1 | high | The same tap means different things by screen. A file in the browser plays its whole folder; in Recents or Search it plays alone. A folder in the browser navigates; in Recents it plays. | One rule: **a file tap plays it in its folder; a folder tap navigates.** Play alone and Play become long-press items. Search and Recents then match the browser, and "Play in Folder" leaves the menus because it is the default. |
| C2 | high | The add sheet is titled "Files" and looks identical to the Files tab, but every tap appends and dismisses. | Title the sheet's root "Add to Playlist" and set it as the prompt on pushed levels. |
| C3 | high | Tapping a file replaces a hand-built playlist with no warning. With Add now a first-class action, that loses real work. | Confirm only when the playlist has had an Add since it was opened: "Replace the playlist?" with Replace and Add Instead. A plain folder playlist still replaces without asking. |
| C4 | med | The bar's Play button plays only the files directly in the folder. In a folder of three albums and one loose file it plays one track, and it vanishes in folder-only directories so the bar shifts between levels. | Keep the button at every level and make it play the folder with its subfolders, in the browser's order. This also resolves B2. If recursion is declined, label the button's menu "Play Songs in This Folder" and keep B2's alert. |
| C5 | med | The Sort menu looks like a view option for this folder but writes the global "When opening a folder" setting. | Keep one setting, but say so: title the menu "Sort All Folders By". Per-folder sort is not worth a second store. |
| C6 | med | The scope bar reads All, Files, Dropbox, Playlist; the result sections read Playlist, Files, Dropbox. The chosen scope also persists, so a later search can look empty. | Order the scope bar as the sections are ordered, and reset the scope to All when the search tab is activated. |
| C7 | low | Open Folder lands on the folder with nothing selected. | Pass the file through `showDirectory:` and scroll to and briefly highlight its row after the listing lands. |
| C8 | low | Signing in from the Files tab leaves the user on the root; they must tap Dropbox again. | On a successful sign-in started from that row, push the Dropbox root. |

## D. Wording and iconography

| # | Sev | Finding | Recommended fix |
| --- | --- | --- | --- |
| D1 | high | The Locations footer says "Vibe can't search your files until you give it a folder", which is no longer true: On My iPhone and Dropbox need no grant. It also describes search under a section about browsing. | "Add a folder from iCloud Drive, a drive, or another app to browse and search it here." |
| D2 | med | "Edit" enters a mode where nothing is edited; the only action is Add to Playlist. There is no Select All and no count. | Rename to "Select". Show the count in the title ("3 Selected") and add Select All on the leading side while selecting. |
| D3 | med | Sort labels are not parallel ("Sort by name", "Date modified, newest first", "Unsorted") and the second wraps in the menu. | "Name", "Newest First", and "Unsorted", in both the menu and Settings. |
| D4 | med | "Files" names the tab, the Settings screen, and a search scope that excludes Dropbox files. | Rename the search scope and its section to "On Device and Folders" or, shorter, "Local". Rename the Settings screen "Files and Dropbox". The tab keeps "Files". |
| D5 | med | Dropbox placeholders show iCloud's glyph (`icloud.and.arrow.down`) in tertiary grey. Dropbox search hits show no cloud at all. | `arrow.down.circle` in secondary label color, and the same accessory on Dropbox file hits in Search. |
| D6 | low | "Play in Folder" and "Open Folder" share one folder icon in the same menu. | `play.square.stack` for Play in Folder (if C1 keeps the item) and `folder` for Open Folder. |
| D7 | low | A recent's second line can show an internal name ("Documents", or the account id for an item recorded under an earlier container path). | Store the folder's display name in the recent when it is recorded, as a favorite stores its location, rather than deriving it from the path at draw time. |
| D8 | low | The disconnect alert is titled just "Disconnect". | "Disconnect from Dropbox?" |
| D9 | low | With nothing downloaded, Remove Downloads is a greyed row reading "Zero KB". | Hide the row until there is something to remove. |
| D10 | low | The Dropbox row uses a generic shipping box, and "Connect to Dropbox…" is a blue action row between two navigation rows. | Ship Dropbox's glyph as a template image (their brand guidelines allow it for integrations), and move Connect to Dropbox… under Locations beside Add Folder… until an account is linked. |

## E. Information density and scale

| # | Sev | Finding | Recommended fix |
| --- | --- | --- | --- |
| E1 | high | Browser rows are bare filenames: no size, duration, artist, or art, and no mark on the playing track. A tap on a 70-minute mix downloads it with no warning. | Two cheap additions, both free of network: the file size as secondary text (already in the stat), and the playing-row marker on the current track. Tags and art only where the metadata cache already holds them; never fetch for a browser row. |
| E2 | med | Everything in Dropbox is listed, including folders with no music, and a long folder has no way to jump or filter. | A filter field in the folder's navigation bar (`UISearchController`, matching names in the listing already on screen). Do not hide folders: whether one holds audio is unknown until it is listed. |
| E3 | med | Video `.mp4` files are listed and played as songs with a music note. | Keep them playable, since some hold only audio, but give `.mp4`, `.m4v`, and `.mov` rows the `film` glyph so the list reads honestly. |
| E4 | low | Long names wrap without limit in the browser (one took four lines) while Search and Recents cap at one. | Two lines, middle truncation, everywhere a filename is drawn. |
| E5 | low | Local file hits in Search are in walk order. | Sort file hits by name within the section as each batch lands. |

## F. Navigation and structure

| # | Sev | Finding | Recommended fix |
| --- | --- | --- | --- |
| F1 | med | The add sheet has a Close button only on its root; a pushed folder offers Back alone. | Put Close on the trailing side of every level of the sheet. In the sheet the bar's Add button then sits beside it, which reads correctly as "add this folder, or close". |
| F2 | med | A Location can be removed only by swiping its row; the root has no Edit button. *(from code)* | Add a long-press "Remove Location" item to location rows. It needs no Edit mode. |
| F3 | low | Recents sits among the sources, and its Clear button is also offered inside the add sheet. | Leave Recents where it is; hide Clear when the browser is the add sheet. |
| F4 | low | Pull-to-refresh exists only in Dropbox folders. | Add it to every directory; for a local folder it just relists from disk. |

## What works well

- Cancelling the sign-in is quiet, with no error alert.
- The Files tab keeps its navigation stack across tab switches.
- The empty-folder and empty-Recents states are clear.
- Clear Recents behind a one-item destructive menu is a good guard.
- Dark mode is clean throughout.
- Dropbox browsing and search were fast against a real account.

# iOS file browser and Dropbox: UI feedback

A usability audit of the UI that PR 132 introduced (the Files tab's browser, Recents, the add sheet, Dropbox browsing and search, and Settings › Files), with a recommended fix for each finding. Nothing here is decided; each recommendation is a proposal to accept, change, or drop.

**How it was audited.** The Debug build was driven in the iPhone simulator with real touches, in light and dark mode, against seeded local folders and a signed-in Dropbox account, on 2026-10-02.

**Not exercised.** iPad, Dynamic Type, VoiceOver, offline and error paths, the two system pickers, removing a Location, and a download slow enough to show the row loading bar. Findings marked *(from code)* were read, not seen.

**Severity.** *bug* is broken; *high* will confuse or mislead; *med* is friction; *low* is polish.

## Status

Sections A and most of B through F are done; each row's last column says what was built. Still open: **B2** and **C4** (what Play and Add do with a folder whose songs are in subfolders), **B3**, and whether the card's download line (**B7**) is legible enough. **C3** is done and may be reverted. The new and reworded strings are English only.

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

| # | Sev | Finding | Outcome |
| --- | --- | --- | --- |
| B1 | high | Add to Playlist gives no confirmation in the Files tab. A full swipe on a folder added four tracks and nothing on screen changed. The context menu and multi-select Add are the same. | **Done.** The added rows lift, then fly into the Playlist tab when the tracks land, with a light haptic; when nothing lands they set back down. No badge. Recents and Search adds do not animate yet, and on iPad the rows fade in place. |
| B2 | high | Adding or playing a folder that holds only subfolders does nothing, silently. Selecting "Albums" (subfolders only) plus one file added only the file. | **Open**, with C4. The rows of an Add that lands nothing now set back down instead of flying, which is the only signal so far. |
| B3 | med | Adding something already in the playlist is skipped silently, and rows carry no mark for what is already there. | **Kept open.** |
| B4 | high | Search with no results is a blank screen. In the Dropbox scope the "Searching Dropbox…" header just disappears. | **Done.** The system's No Results state, once every half in scope has answered with nothing. |
| B5 | med | A Dropbox search failure looks the same as no results; the error is only logged. | **Done.** A failed Dropbox search heads its section "Couldn't reach Dropbox." instead of vanishing. |
| B6 | med | A failed Dropbox relist is invisible when the folder already has rows, so a stale listing looks current. *(from code)* | **Done.** A footer under the rows while the last relist failed. |
| B7 | med | The now-playing card shows no download progress. While a Dropbox track downloads it shows `--:--`, a flat line, and a Pause button. | **No change needed.** The card already draws the transfer as a fill along the waveform's line; the audit judged it from one frame of a file that downloaded in under a second. Whether that thin line is legible enough is still open. |
| B8 | low | "Searching Dropbox…" is a plain section header and reads as a label. | **Done.** A spinner in the section header while Dropbox is asked. |

## C. Predictability

| # | Sev | Finding | Outcome |
| --- | --- | --- | --- |
| C1 | high | The same tap means different things by screen. A file in the browser plays its whole folder; in Recents or Search it plays alone. A folder in the browser navigates; in Recents it plays. | **Done, with the rule flipped as decided:** a file tap plays that file alone and a folder tap opens it, in the browser, Search, and Recents. The long press has Play in Folder. |
| C2 | high | The add sheet is titled "Files" and looks identical to the Files tab, but every tap appends and dismisses. | **Done.** The sheet's root is titled Add to Playlist and every pushed level carries it as a prompt. |
| C3 | high | Tapping a file replaces a hand-built playlist with no warning. With Add now a first-class action, that loses real work. | **Done, and may be reverted.** A replace asks first (Replace, Add Instead, Cancel) once an Add has landed on the playlist; it is one method, `+confirmReplacingPlaylistOf:from:replace:add:`, and four call sites. |
| C4 | med | The bar's Play button plays only the files directly in the folder. In a folder of three albums and one loose file it plays one track, and it vanishes in folder-only directories so the bar shifts between levels. | **Open: needs a decision.** Play still plays the files directly in the folder. Recursing risks pulling in a huge library; a bounded recursion (a track cap) is the candidate. |
| C5 | med | The Sort menu looks like a view option for this folder but writes the global "When opening a folder" setting. | **Done.** The menu is titled "Sort All Folders By" and stays in the Files tab's bar. |
| C6 | med | The scope bar reads All, Files, Dropbox, Playlist; the result sections read Playlist, Files, Dropbox. The chosen scope also persists, so a later search can look empty. | **Done.** The scope bar is All, Playlist, Local, Dropbox, and an appearance with an empty field resets it to All. |
| C7 | low | Open Folder lands on the folder with nothing selected. | **Done.** The file is scrolled to and selected for a moment. |
| C8 | low | Signing in from the Files tab leaves the user on the root; they must tap Dropbox again. | **Done.** A sign-in from the Connect row pushes the account's root. |

## D. Wording and iconography

| # | Sev | Finding | Outcome |
| --- | --- | --- | --- |
| D1 | high | The Locations footer says "Vibe can't search your files until you give it a folder", which is no longer true: On My iPhone and Dropbox need no grant. It also describes search under a section about browsing. | **Done.** |
| D2 | med | "Edit" enters a mode where nothing is edited; the only action is Add to Playlist. There is no Select All and no count. | **Done.** A checkmark glyph labelled Select (the word truncated the folder's name), a count for a title, and Select All. |
| D3 | med | Sort labels are not parallel ("Sort by name", "Date modified, newest first", "Unsorted") and the second wraps in the menu. | **Done.** "Name", "Newest First", and "Unsorted", under "Sort folders by" on both platforms. |
| D4 | med | "Files" names the tab, the Settings screen, and a search scope that excludes Dropbox files. | **Done.** The scope and section are "Local"; the Settings screen is "Files and Dropbox". |
| D5 | med | Dropbox placeholders show iCloud's glyph (`icloud.and.arrow.down`) in tertiary grey. Dropbox search hits show no cloud at all. | **Done.** `arrow.down.circle` in secondary label color, in the browser and on Dropbox file hits. |
| D6 | low | "Play in Folder" and "Open Folder" share one folder icon in the same menu. | **Done.** `play.square.stack` for Play in Folder. |
| D7 | low | A recent's second line can show an internal name ("Documents", or the account id for an item recorded under an earlier container path). | **Done.** A recent records its folder's display name; ones recorded before this still derive it. |
| D8 | low | The disconnect alert is titled just "Disconnect". | **Done.** |
| D9 | low | With nothing downloaded, Remove Downloads is a greyed row reading "Zero KB". | **Done.** The row is absent until something is downloaded. |
| D10 | low | The Dropbox row uses a generic shipping box, and "Connect to Dropbox…" is a blue action row between two navigation rows. | **Done.** A template Dropbox glyph, and Connect to Dropbox… sits under Locations until an account is linked. |

## E. Information density and scale

| # | Sev | Finding | Outcome |
| --- | --- | --- | --- |
| E1 | high | Browser rows are bare filenames: no size, duration, artist, or art, and no mark on the playing track. A tap on a 70-minute mix downloads it with no warning. | **Done.** The file's size, and a speaker on the playing file. No tags or art. |
| E2 | med | Everything in Dropbox is listed, including folders with no music, and a long folder has no way to jump or filter. | **Done.** A filter field, tucked away until the list is pulled down. |
| E3 | med | Video `.mp4` files are listed and played as songs with a music note. | **Kept as is.** |
| E4 | low | Long names wrap without limit in the browser (one took four lines) while Search and Recents cap at one. | **Done.** |
| E5 | low | Local file hits in Search are in walk order. | **Done.** |

## F. Navigation and structure

| # | Sev | Finding | Outcome |
| --- | --- | --- | --- |
| F1 | med | The add sheet has a Close button only on its root; a pushed folder offers Back alone. | **Done.** Close at every level; the sheet's bar drops the sort menu to make room. |
| F2 | med | A Location can be removed only by swiping its row; the root has no Edit button. *(from code)* | **Done.** |
| F3 | low | Recents sits among the sources, and its Clear button is also offered inside the add sheet. | **Done.** |
| F4 | low | Pull-to-refresh exists only in Dropbox folders. | **Done.** |

## What works well

- Cancelling the sign-in is quiet, with no error alert.
- The Files tab keeps its navigation stack across tab switches.
- The empty-folder and empty-Recents states are clear.
- Clear Recents behind a one-item destructive menu is a good guard.
- Dark mode is clean throughout.
- Dropbox browsing and search were fast against a real account.

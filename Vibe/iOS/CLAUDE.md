# iOS app shell (VibeiOS target)

The iPhone and iPad app: a single-folder player where **the current directory is the playlist**. The user picks a folder (or file) in the system document picker; the folder's audio files become the playlist, in the order `AppSettings.folderOpenSort` names (below). Dropbox and iCloud work through their Files file-providers in the picker — no provider SDKs.

**The shape is Apple Music's.** Two tabs — Playlist and Files — in a capsule with search as a *circle* beside it rather than a third tab inside it, a mini player strip above them, and the now-playing screen as a full-screen card that presents up from the strip and swipes down to go back. Opening files or a folder replaces the playlist, starts playing, brings the Playlist tab forward and presents the card — so putting the card away lands on what was just opened rather than back in the Files browser. Search is the exception, since `UISearchTab` owns the selection while its field is up.

**This directory is the app shell and nothing else.** The iOS halves of shared subsystems are documented where they live: `Audio/iOS/`, `WaveformUI/iOS/`, `Util/iOS/` each have their own `CLAUDE.md`.

The target compiles this plus every shared subsystem minus that subsystem's `Mac/` half — see the root `CLAUDE.md` on the directory being the platform boundary. **A new file in a shared directory joins this target automatically** and must be AppKit-free or `TARGET_OS_OSX`-guarded; CI's `build-ios` job is what catches a leak.

On iPad the app is a resizable iPadOS 26 window (all four orientations, no `UIRequiresFullScreen`; minimum 320×480 via `sizeRestrictions` in `VibeiOSSceneDelegate`, the portrait layout's floor). **The portrait/landscape layout switch keys off view aspect**, so window shape — not device orientation — picks the layout.

**Multi-scene is off, deliberately**: there is one `AudioPlayer` per `PlaybackController` and one `PlaybackController` per scene, so a second scene would spawn a second engine. A size transition sets `_windowResizeInFlight`, which holds `commitVisiblePage` — a mid-resize offset rounds to a neighbor page and would otherwise switch tracks.

## What is where

The longest file in the tree, so: **[The model](#the-model)** is `PlaybackController`, everything the app plays and nothing that draws it, plus **[FolderSession](#foldersession)**, the picked location's owner. **[The shell](#the-shell)** is everything that draws, one heading per screen — `RootViewController` (the app's shape), `MiniPlayerView`, `FilesViewController`, `LibraryViewController`, `SettingsViewController`, `SearchViewController` with `FileSearchIndex` and `SearchFolderStore` behind it, and `PlayerViewController` — the card — with `TrackPageCell` and `PageWaveformCoordinator`. **[Building and verifying](#building-and-verifying)** is the simulator loop and the debug channel's iOS half.

## The model

**`PlaybackController`** — everything the app plays and nothing that draws it: the engine, the `Playlist`, the metadata cache, the audio session, the `FolderSession`, the Now Playing bridge, the 3 Hz `UIUpdateTimer`, and the display state those resolve to. It is the model half of what the mac's `MainPlayerController` is. The scene delegate owns the one instance; every screen borrows it.

**It broadcasts, where the rest of the app uses a single weak delegate**, and that is the reason the class exists. Three views describe the same playback at once — the library row's playing indicator, the mini strip, and the card — and `Playlist` has exactly one observer slot, so the fan-out had to live somewhere other than a view controller. `PlaybackObserver` is delivered synchronously on main, in registration order, through a weak `NSPointerArray`. **Weak is load-bearing**: an observer is a view or view controller, and outlives its registration only by accident.

Two categories, both the mac's split brought over with contracts intact:

- **`+PlayerEvents`** — every `AudioPlayerDelegate` callback. Same two rules as the mac's: **every callback can be stale** and must match the delivered track against the playlist's current one, and **`stop` fires no callback**, so nothing there drives auto-advance.
- **`+NowPlaying`** — the publish and the remote-command routing, landing on the same transport entry points the screens' own controls use. `notifyDidTick` **publishes before it ticks**, so the lock screen can never lag the screens.

`PlaybackControllerInternal.h` is the private surface those categories share.

**A scrub on a parked track seeks; it does not start playback.** Parked, the player holds no file, so its duration is 0 and there is nothing to seek *in* — `seekToProgress:` therefore opens the file **at** the scrubbed position and opens it **paused**, taking the length from metadata. The seek target outranks Loading in the card's two progress paths for the same reason: that open is Loading and seeking at once, and zeroing the waveform there is the snap-back the target exists to prevent. `didStartPlaying:` clears the in-flight flag, since this seek has no `didFinishSeeking:` of its own.

**The playlist-wide metadata sweep waits for the picked track to settle** — the mac's rule brought over: `folderSession:didOpenTracks:` schedules it, `didStartPlaying:` and the error path start it, and a two-second fallback covers an open that never lands. On a file-provider folder each of four workers' reads is a whole download. That scheduling is the whole of the shell's half; the rule it sits on top of is `AudioFileMaterializationCoordinator`'s and carries no shell or cache state at all — root `CLAUDE.md`, Cross-directory guarantees.

**The display state is resolved in one place**, `PlayerScreenRules.h` — header-only, Foundation-only and tested from the macOS suite — rather than re-derived from `_parked`, `_trackStartPending`, `_errorText` and the rest at each site. `screenState` gathers the inputs; the card, the mini strip (`VibeMiniPlayerVisible`), the Now Playing publish and the debug dump all read the result. Its mac twin is `TrackDisplayRules.h`; the two enums are deliberately separate, since this screen has no launch grace and parks tracks the mac has no equivalent of.

**Three of the mac's features are off here**, each at one place rather than compiled out: no DJ FX (the engine is created with `enableFX:NO`), no folder art (`AudioTrackArtwork` leaves its resolver handle nil), and no BPM or key analysis (the decode pass's analysis provider is unset). The settings behind all three are macOS-only in `AppSettings`, so there is nothing here to read that could disagree. **The 128px thumbnail is not on that list** — the library rows and mini strip draw one. Rows archive compact bytes, while decoded thumbnail pixels live in `AudioTrackArtwork`'s shared 128-image LRU instead of growing with the playlist. An eviction returns the placeholder immediately, enters one bounded off-main decode, and refreshes only visible Library, Search and mini-player surfaces when it lands. **TRAP: UITableView's prepared cells are rendered while not yet "visible" and are displayed without re-running `cellForRowAtIndexPath:`** — a decode or metadata delivery landing in that window repaints nothing, so the Library re-renders each cell in `willDisplayCell:`, the one edge where "about to be seen" is knowable; without it a row scrolls in frozen on the placeholder with its pixels already decoded.

## FolderSession

The picked location's owner: picker presentation, the security scope, the bookmark that restores the folder on relaunch (default `bookmarkData`; iOS has no `WithSecurityScope` option and does not need it), and the listing via `NSURLUtil audioFilesInDirectory:sortedBy:`.

**The listing order rides the open snapshot, like everything else here.** `AppSettings.folderOpenSort` — Settings > When opening a folder, shared with the mac's Files pane — is read on main at each of the three entry points (`adoptURL:`, `openFileFromSearchRoots:`, `restorePersistedFolder`) and passed down to the worker, so an open cannot straddle a Settings change and the walk never reaches a setting itself (`Util/CLAUDE.md`). Newest-first is the same modification date the Files browser sorts by, which the provider answers as metadata without downloading anything.

**The security scope is held for the whole session** — the player, TagLib and the waveform loader read under it at arbitrary times — and released only after a successor is in hand.

**Adoption happens on the session's own concurrent queue, never main**: bookmark resolution and the listing are both file-provider IPC that can run seconds on a cloud folder, so a newer open must not wait behind an older blocked provider. Every request carries `openIntentGeneration`; only the newest may deliver or persist, and each worker takes a temporary hold on the live security scope it reads so a successor can replace the session safely.

A single-file pick is a one-track playlist: **iOS grants no sibling access from a file grant.** A *folder* grant, by contrast, covers the whole subtree, which is what `searchRoots` and `openFileFromSearchRoots:` are built on — the latter expands a search hit deep in the tree to its own directory as the playlist, and deliberately leaves the grant and the bookmark alone: the scope in hand already covers it, and re-pointing the bookmark at a subfolder would shrink next launch's searchable root to it. A relaunch restore **parks** the remembered track — header, waveform, metadata loaded, nothing playing, card left minimized — and the scene delegate runs exactly one of restore-or-adopt at launch, so a cold "Open in Vibe" never pays for a restore it immediately replaces.

Persistence is `FolderSession`'s own `NSUserDefaults` keys (`VibeiOSFolderBookmark`, `VibeiOSLastTrackFileName`), deliberately not the shared `AppSettings`.

## The shell

### RootViewController

The scene's root and the app's shape: a `UITabBarController` child, the mini player in its `bottomAccessory`, and the card above both. It owns expand and minimize, and is the only thing that knows whether the card is up.

**The tabs are `UITab`s, not view controllers**, which is what buys the Apple Music shape: `UISearchTab` draws the search circle *outside* the capsule, and its `automaticallyActivatesSearch` is what makes tapping it collapse the bar behind a search field and restore the previous tab on cancel. Each tab builds its view controller through a lazy provider, so a tab never visited costs nothing — which matters most for Files. The Files inset path reads `_filesController`, assigned only by that provider; reading `UITab.viewController` to ask whether it exists would itself resolve the provider and defeat the laziness. The search tab's identifier is UIKit's rather than ours, so `selectedTabIdentifier` matches it by kind and the other two by the identifiers we minted.

**A container, not a `UITabBarController` subclass.** The card has to sit above the tab bar controller's whole view so the screen behind it can scale back, and a subclass cannot transform its own view without dragging the card along with it.

**The card is built once and never torn down.** Minimizing translates it off the bottom; it is not presented and not dismissed. Its pager, art window and waveform snapshots have to survive a minimize, or every expand would pay a re-read and re-decode of art already in memory. Its art is deliberately not pruned on minimize either — the byte budget already bounds retention, and pruning would cost a placeholder flash on the way back up.

**TRAP: the card moves by TRANSFORM and never by frame.** Its pages carry `WaveformScrubberView`s, and a scrubber tears down its baked envelope bitmap and re-bakes it 0.6s later on any bounds change — over a layer tree twice the view's width. Animating the card's frame would pay that on every expand, on every page. `dump_state`'s `ui.waveformBaked` is how to check it stayed baked.

**TRAP: `shouldAutomaticallyForwardAppearanceMethods` is per-parent, not per-child.** Only one child is on screen at a time, so this controller says when each appears — but turning forwarding off for the card turns it off for the tabs too, which is why both are forwarded by hand. Each parent begin snapshots its exact children and the matching end consumes that snapshot; `_expanded` can change between the callbacks and must not change who receives the end.

The scene delegate's foreground-active bit drives both the Library surface and the card's display link. Foreground-inactive is off, not a halfway foreground. The custom card transition also owns what UIKit presentation would normally supply: Reduce Motion turns the spring into an immediate settle, the card becomes the modal accessibility surface while up, and completion moves VoiceOver focus into the newly active surface.

### MiniPlayerView

The accessory's content: artwork (the 128px thumbnail, never the card's full-size decode), title over artist, play/pause and next. Metrics are Apple Music's: **the tap targets stay large and the glyphs are small** (`kGlyphPointSize`, 19), because sizing the button instead of the symbol made ours read as buttons rather than as a transport. Next is `forward.end.fill`, the glyph the mac draws — one transport vocabulary across both apps.

**TRAP: the row needs a designated give, and the simulator will never tell you.** The strip is pinned to the edges of UIKit's accessory container, and on device that container reports a width of **zero** on at least one pass — where the rest of the row is required and needs 162pt (12 + art + 10 + 6 + two 44pt controls + 8). UIKit then breaks whichever constraint it likes and logs the whole conflict on every launch. The art's leading inset is therefore `UILayoutPriorityRequired - 1`: below required, that pass just slides the left block off and costs nothing, and at any real width the 12pt is honored exactly. Any new required constraint spanning this row reopens it.

**TRAP: the strip is 48pt and that is not negotiable.** `UITabAccessory` frames its content view at a fixed system height — an `intrinsicContentSize` is ignored, and so is an explicit height constraint, *without logging a conflict*, because UIKit never asks Auto Layout to size it. A taller strip means giving up the accessory, and with it the Liquid Glass, the collapse-inline behavior and the automatic safe-area inset for the tab children.

**There is deliberately no playhead bar**, for the same reason: one fits in 48pt only by taking a slice off the top and pushing the artwork and labels into what is left. Apple Music draws none either, and nothing in the shell reads the position tick as a result.

`traitCollection.tabAccessoryEnvironment` — set by UIKit on everything inside a `bottomAccessory` — is what tells it the tab bar has collapsed it inline, where the artist line is dropped.

### FilesViewController

The Files tab: `UIDocumentBrowserViewController`, the system's own browser over every Files provider. A picked file goes through `PlaybackController.openExternalURL:openInPlace:` — the same road the picker takes.

**This tab opens FOLDERS too, and that is why the playlist screen needs no Open button.** `UTTypeFolder` leads its content types, so navigating into a folder puts an **Open** button in the browser's own top right that hands that directory back through the same delegate — and `openExternalURL:openInPlace:YES` funnels into `FolderSession.adoptURL:`, exactly where the document picker's own delegate lands. The subtree grant, the directory-as-playlist listing and the persisted folder bookmark are therefore bit for bit what the picker produces. Only the empty state still presents a picker, for the first run. It is the browser rather than an embedded `UIDocumentPickerViewController` because the picker is a modal presentation and unsupported as a child, and it takes **no navigation controller**: the browser brings its own bar and hierarchy, and wrapping it stacks two.

**TRAP: it needs `additionalSafeAreaInsets` for the mini strip, and it is the only tab that does.** UIKit insets tab children for the tab bar but **not** for the `bottomAccessory`, and the browser places its own Recents/Shared/Browse bar against its safe area — so with the strip up that bar ends up half underneath it. A scroll view never shows this, because it just receives extra content inset; a view controller that positions its own chrome does. `RootViewController.applyFilesBottomInset` **measures the live accessory** rather than assuming 48pt, so a system height change cannot silently reopen the overlap.

### LibraryViewController

The Playlist tab, and the home screen. The mac playlist table's four columns re-proportioned to Apple Music's list: number — replaced on the playing row by `EqualizerIndicatorView`, the very same bars the mac table draws, which is why that class is in the shared `Vibe/Controls/` — artwork, **title over artist on two lines**, and the duration out on the right.

**The bars follow the audio, from the same analyzer the mac uses** — tapped at a different node, since the FX segment is absent here; `Audio/Levels/CLAUDE.md` owns the producer rule and `Controls/CLAUDE.md` owns the renderer. The cell is handed `PlaybackController` as its narrow `EqualizerLevelSource` at dequeue.

**Activity means actual output plus material visibility, not play intent or view attachment alone.** `PlaybackController.audioOutputActive` comes from the engine and remains true for an audible outgoing fade, but not for a Loading request that has no audio yet. `LibraryViewController` combines its own presentation with `willDisplayCell:` / `didEndDisplayingCell:` row state. `RootViewController` adds tab and card exposure explicitly because the card moves by transform over children that stay attached and "appeared" (`shouldAutomaticallyForwardAppearanceMethods` is NO here). Interactive and interrupted card transitions keep that exposure honest throughout the gesture rather than guessing from a final `_expanded` value. The scene delegate supplies foreground-active state separately.

Only when all of those facts are true does the playing row start its snapshot poller. Starting declares one `equalizerLevelsWanted:` consumer; stopping invalidates the poller, removes its explicit animations, collapses the bars and balances that demand. `PlaybackController` counts the consumers, and the player removes the tap at zero. Cover the row with the card, switch tabs, scroll it away, background the scene, pause or stop and both the poller and FFT stop. Cell reuse can briefly hold two consumers, which is why the gate is counted rather than a boolean.

Track changes scroll the playing row only while this surface is materially visible. Hidden changes retain one pending index; the next reveal parks there once without animation instead of running table layout and scroll animation behind another tab or the card.

**The number gutter has three states, in precedence: loading, playing, number** — the cell's `resolveGutter`, driven by `loading` (from `CloudTransferRegistry.isTransferringURL:`, a provider transfer really running for the row's file) and the row's playing flag. Loading outranks playing: while the open is in flight there is no output audio, so the equalizer would be collapsed dots. The bar is the shared `LoadingIndicatorView` in the indicator's slot, appearance-colored (no forced white here). A loading row's equalizer must not keep a demand-declaring poller behind the bar, so `syncEqualizerActivityForCell:` folds `!loading` into both activity facts. On a registry change the controller re-syncs `visibleCells` in place — never a reload — and `didEndDisplayingCell:` and `prepareForReuse` both drop `loading`, so an off-screen row cannot hold a live sweep animation.

`dump_equalizer` is the runtime proof for both halves: while active, `renderer.displayTicks` is a poll count bounded at 30 per second, `renderer.transformWrites` counts model-target and immediate reconciliation writes, and `renderer.geometryLayouts` stays flat while bounds are stable. Publication flow adds at most one transform write per materially changed bar; geometry, source or activity reconciliation and one stale-to-zero settle can add one changed-bar pass of their own. After an inactive transition settles, the audio counters and `displayTicks` must stay flat; geometry and transform writes additionally require no resize, scrolling or cell population. **`--silent` forces the tapped post-mixer signal to zero**, so flat bars under the debug scripts' default launch do not test this feature. Use `VIBE_AUDIBLE=1` for reactive simulator validation; `--no-audio-hw` by itself preserves reactive manual rendering but is not valid for audible-start-latency measurements.

The number and duration take the **artist line's text style**, not a fixed size, so the three secondary columns scale together under Dynamic Type instead of agreeing only at the default size.

An empty playlist gets `UIContentUnavailableConfiguration` with the same Open action, saying something different when the last pick found no audio. **Selecting a row plays it and stays here** — expanding the card is the strip's job, not a side effect of picking a track.

The folder name goes on `navigationItem.title`, **not `self.title`**: the latter is also the tab bar item's title, and the open folder's name is not what the tab is called.

The bar carries **the gear and nothing else**. There is deliberately no Open button beside it: the Files tab opens folders as well as files (above), so one there would be a third door to the same room. The empty state keeps its own Open action, which is the first run, where there is no Files tab visit to have made yet.

### SettingsViewController

Behind the gear, **pushed onto this tab's navigation stack rather than presented** — everything on it is something the mini strip or the card behind it draws, and both stay up. A grouped list: the waveform style (one row per registered renderer, sorted by localized display name, checkmark on the resolved style — never the raw stored one, or an identifier nothing draws would still be ticked), the waveform theme, the time display, the file-info switch, the folder-open order, and the searchable folders.

**"When opening a folder" is the one section that notifies nothing.** It is not a display setting — no screen draws from it, and it governs the next folder open — so its case writes `AppSettings.folderOpenSort`, reloads its own section for the checkmark, and returns before the notification every other row posts. It sits below everything the player draws and above the search folders, with which it shares being about files rather than pixels.

**It writes settings and posts; it never reaches for the screens that draw them.** The card is the only thing that has to react and it is elsewhere in the app, so `VibeDisplaySettingsDidChangeNotification` carries it — see the card's `displaySettingsDidChange`. This is the one place a notification is right where the mac would use a direct live-apply hook (`Common/CLAUDE.md`): the settings screen and the card have no owner in common below `RootViewController`.

**`PlayerDisplaySettings`** is the store behind two of them: `VibeiOSShowRemainingTime` and `VibeiOSShowFileInfo`, iOS-owned keys beside `FolderSession`'s and the waveform zoom's. Deliberately *not* `AppSettings`' equivalents — those sit inside its macOS-only block because they are read on every playback tick and ride the hot cache that block exists for, and iOS reads these a few times a second. File info defaults to **on**, which is the mac's default, so the absence of the key is tested rather than registered. The waveform style is the exception and is a shared `AppSettings` property: both platforms draw waveforms and both now offer the picker.

### SearchViewController

Behind the search circle: a `UISearchController` over **two** sections — the playlist, and the audio files reachable anywhere under the locations the app holds. It installs the field on its own `navigationItem`, and `UISearchTab` hoists that field into the collapsed tab bar — so there is **one** search controller, not one per bar. It deliberately does not focus the field on appear.

**The two sections are deliberately unsynchronized, and that is the feature.** The playlist half is a synchronous pass over `Playlist.tracks` and lands on the same run-loop turn as the keystroke. The files half snapshots whatever the walk has delivered and performs localized matching on its own serial user-initiated queue; each query or arriving batch supersedes the older pass, and only the latest answer reloads that section on main. Neither waits on the other or on a provider listing.

The empty query lists the whole playlist, so that section doubles as a browse list; the files section is empty there, because a recursive dump of a provider tree is not a browse list. A section with no rows draws no header, so a query with no file matches leaves no bare heading — the one exception is a walk still running, where the heading plus a "Searching files…" footer is how a partial answer says it is partial.

It re-*filters* rather than merely reloading on a playlist change, because its rows are indexes into a playlist that has just been replaced. A playlist change is also a new exclusion set (below) and possibly new roots. `viewWillAppear` refreshes unconditionally. Root supplies the separate material-surface fact the child cannot infer from UIKit: expanding the custom card cancels hidden file matching, and revealing Search starts one current pass rather than replaying every batch that arrived behind it.

**A playlist row is a selection and stays here; a file row is an open.** Its folder becomes the playlist with it selected, so observers see a new folder open and the card presents — the same road every other open takes.

**The table dismisses the keyboard on drag, and it has to.** `UISearchTab` hoists the field into the *tab bar*, so the keyboard covers the results rather than sitting under a field inside them, and without `keyboardDismissMode` nothing on this screen ever puts it away — the bottom half of a result list is simply unreachable. Not `interactive`: that mode tracks a field the scroll view contains, and this one does not contain it. Picking a row resigns the field too, but leaves the query in it, so the results stay put for a second pick.

### FileSearchIndex

The files section's data: one streaming walk into memory, then a latest-wins filter per query away from main.

**There is no public API that searches the Files app.** No search hook on `UIDocumentPickerViewController` or `UIDocumentBrowserViewController`, and `NSFileProviderSearchQuery` is the provider *extension*'s side, not a host app's. An app can only search trees it actually holds — which is why the scope is something the user grants, folder by folder (`SearchFolderStore`, below).

**`PlaybackController.searchRoots` composes the scope, and it is the only place that does.** Two halves, and the split is load-bearing:

- **transient** — `FolderSession.searchRoot`, the open folder. Its grant covers the whole subtree, which the flat directory-as-playlist listing never reaches. Gone at the next open.
- **persistent** — `SearchFolderStore.searchRoots`: the folders the user added in Settings, plus the app's own **Documents** directory, which is what Files shows as "On My iPhone → Vibe" and needs no grant at all.

Roots nested inside one another are pruned by the index, so a folder added *inside* Documents cannot list every file in it twice.

**The walk reads directory listings and nothing else** — never a file's bytes, never its tags — so a provider tree costs IPC per directory and no downloads. It runs at `QOS_CLASS_UTILITY` on its own serial queue: a listing is the same provider IPC an open needs, and the open the user is waiting on outranks it (root `CLAUDE.md`). It starts on the search screen's **appearance**, not on the first keystroke — arriving there is the signal the work is wanted, and it is what lets the first query answer off an index already filling — and never before, so the other two tabs pay nothing.

Batches land on main every 128 files or 200ms, whichever comes first; the interval is what makes results appear promptly on a provider tree where one listing can take a second by itself. `buildGeneration` is stamped on the walk and checked on every batch, so a root change drops a walk in flight rather than mixing its results into the next index. The walk folds filename + folder text once off-main. Query work snapshots the current files, checks its own generation throughout the background pass, and an unchanged query scans only the suffix appended since its prior answer rather than repeating the whole prefix after every batch. It returns at most 200 rows. The index itself caps at 20,000 files and logs when it stops, keeping both the snapshot and a broad query bounded.

**A hit is named entirely from its path**, filename over containing folder, with a `music.note` glyph rather than art — nothing was stat'd, read or parsed. The folder name is *matched* as well as drawn (`FileSearchRules.h`), because on a music tree that folder is the album or the artist, and it is how a directory of tracks named nothing like the query gets found.

**A track the playlist already lists is not offered twice.** The screen passes its playlist paths as the exclusion set, rebuilt on a playlist change rather than per keystroke, and the index tests it before the string match because a set lookup is the cheaper of the two. Each hit carries its `path` for exactly that, so a keystroke never recomputes `NSURL.path` per row.

`FileSearchRules.h` is the matching rule for **both** sections, tested from the macOS suite: a filename that matched in one and not the other would read as a broken walk rather than as two comparisons that drifted apart. The one place the two deliberately disagree is the empty query — no constraint for the playlist, no match at all for a file. It also holds `VibeSearchRootCoversPath`, the coverage decision the index's pruning and the settings list's "you already added a folder that reaches this one" both read, so those two cannot drift either.

### SearchFolderStore

The folders the user handed the app to search, and the grants that make them readable: a persisted list of security-scoped bookmarks, each scope started at launch and held for the session. A singleton, and the iOS twin of the mac's `FolderAccessManager` — the same job, the folders the app keeps access to, listed in a settings pane. Its own `NSUserDefaults` key beside `FolderSession`'s and `PlayerDisplaySettings`', deliberately not an `AppSettings` property: there is no macOS counterpart to keep it in step with.

**A folder here is search scope and nothing else.** Not a second way to open something — tapping a search hit already opens its folder as the playlist, so a folder on this list becomes playable *through search* without the list competing with the Files tab.

**Coverage is tested against the persistent roots and never against the open folder**, and that asymmetry is the point. A grant reaches the whole subtree, so adding a subfolder of a listed folder — or anything inside the app's own Documents — buys nothing and is refused with a word rather than in silence, since silence reads as the pick having failed. But the session's root is gone at the next open, so refusing a folder because it happens to be open *right now* would drop a grant the user wants the moment they open something else. A folder that **covers** existing rows replaces them, and a restored folder some root now covers is dropped: a row that contributes nothing is a lie.

**Bookmark work never blocks main and one provider cannot head-of-line every root.** Launch restoration resolves at most three bookmarks concurrently and merges each result on main in original order; newly added bookmark minting has its own serial queue. Minting needs the scope *open*, so a stale bookmark can only be refreshed after resolving — the same ordering `FolderSession` documents. A parent that replaces narrower rows owns their scopes and durable bookmarks until its own mint lands; pending restoration identities remember a removed covering parent, so a late child cannot resurrect a row the user removed.

Opening a search hit hands `FolderSession` a retained grant object for the exact covering entry. Removing its Settings row hides it immediately but defers `stopAccessingSecurityScopedResource` until the playlist and every overlapping open release that grant; later metadata, waveform and sibling reads therefore keep the access that made the playlist valid.

**It posts `VibeSearchFoldersDidChangeNotification`; Settings and Search both derive their rows from that one delivery.** Appearance alone is not enough: independent launch resolves can land while either screen is already up, and local insert/delete animation beside the notification would mutate the table twice.

`restorePersistedFolders` runs at launch **beside** the scene delegate's restore-or-adopt rather than as a third branch of it — it opens nothing and plays nothing, so it is not exclusive with either. Results publish incrementally; a stalled bookmark occupies one bounded slot rather than withholding every later root.

The channel cannot drive the system document picker (it is another process's UI, out of reach of the touch driver too), so `dump_search`, `add_search_folder` and `remove_search_folder` exist to inspect and set up a scope for a test. **TRAP: a folder added through the channel is not security-scoped and survives only the session** — a test that relaunches must add it again.

### PlayerViewController — the card

The track pager and the chrome over it. It observes `PlaybackController` and owns no playback state.

- **`+Pager`** — the collection view's data source and layout, size-transition re-paging, per-page waveform bookkeeping, and `commitVisiblePage`. **Playback does not switch as pages appear; only the settled page commits.**
- **`+Delivery`** — where the pager's asynchronous results land: waveform snapshots, and the scrubber's seek. Metadata is not here; it is the model's delivery and arrives as a `PlaybackObserver` event.

`PlayerViewControllerInternal.h` is the surface those categories share.

**The output-route indicator rides the page, in the middle of the time row.** Apple Music's placement — one row above the transport, between the elapsed and remaining times, which are bounded against it rather than against the centerline. It is a page's control for the same reason the transport is, so both constraint sets carry it: landscape has the transport on the time row's centerline already, so there it takes the top-trailing corner instead and the codec line is bounded against its leading edge. **Playing out of the phone, it draws the AirPlay glyph and nothing else** — the on-device state is the one the control exists to change, so at rest it advertises what tapping it does rather than describing a speaker the user is already listening to. Only once the audio is somewhere else does the glyph describe that somewhere, with the device's name beside it: **the name is what "off-device" means**, drawn at full strength beside a full-strength glyph, against the secondary weight the resting state shares with the time labels either side of it (`Audio/iOS/OutputRouteRules.h` decides all of it).

`AVRoutePickerView` is the only public way to raise the system picker and there is no programmatic present, so `OutputRouteView` fills its bounds with one, tints cleared, as an invisible tap surface under our own non-interactive icon and label — **verified by tapping the far end of the name, 70pt from where the picker's own glyph sits.** The press dip is ours for the same reason: the highlight AVKit draws is on a transparent glyph. **Its class joins the transport row in `gestureRecognizerShouldReceiveTouch:`'s decline list**, because what hit-tests inside it is AVKit's own view and declining on a class we own does not depend on that view happening to be a `UIControl`. The controller pushes one route to every visible page (a neighbor would keep the old one until recycled) and stamps the chrome alpha on it at dequeue beside the transport's.

**The picker's sheet holds the playhead display link, and the hold releases itself.** `AVRoutePickerViewDelegate`'s begin edge takes it; **TRAP: the end edge is not guaranteed — measured on the simulator, where there is no second route to offer, the begin arrives and the end never does**, which would freeze the waveform under correct time labels for the life of the process. A generation-stamped deadline is the release that does not depend on AVKit, with the scene-active edge settling it sooner; overshooting a sheet still up costs only an animated waveform nobody can see. The end edge also re-reads the route, because a destination picked against an inactive session posts no route notification at all. `dump_state`'s `ui.routePickerUp` is how to see the flag from outside, and `set_output_route` draws any route kind for a look — the simulator reports the built-in speaker and nothing else.

**`presented` is the gate that makes a keep-alive card safe.** Minimized, the card is still laid out and still reloads, so two things must not run: `commitVisiblePage` — a playlist replacement settles a scroll nobody performed, and committing it would change track under a user looking at the library — and the playhead's display link, which would animate a waveform nobody can see. The link additionally reads the exact `sceneActive` supplied by the scene delegate, never process-wide foreground/background notifications.

**The swipe down is arbitrated on axis, in `gestureRecognizerShouldBegin:`.** A horizontally-paging scroll view's pan begins on movement in *any* direction, so the minimize pan has to beat it to the touch: the pager's pan requires it to fail, and it fails on the first move of a horizontal drag.

**TRAP: the axis test is on TRANSLATION, not velocity.** Velocity is sampled over the last few touch events and reads zero whenever the finger pauses — including the moment a slow deliberate drag crosses the recognizer's slop, which is exactly when this is asked. Translation is monotonic and always past the slop by then.

**TRAP: the scrub lock's release is matched against the view that took it, not against the bound page.** Playback runs on through a scrub — the seek only commits on lift — so a track ending mid-drag rebinds `_waveformView` to the next page while the finger is still down on the outgoing one. Filtering the lift on the binding drops it, and **the pager stays unswipeable**. See `WaveformUI/iOS/CLAUDE.md` for why the pager must be held still at all.

`TrackPagerView`, in `PlayerViewController.m`, declines its own pan for touches that hit-test into a loaded `WaveformScrubberView` — the other half of the same problem, and likewise documented in `WaveformUI/iOS/CLAUDE.md`. An unloaded scrubber disables its pan and the pager must accept that same surface, or the loading strip becomes a swipe dead zone.

**A two-finger touch on this screen is a waveform zoom, never a page swipe.** The *pager's* pan is capped at `maximumNumberOfTouches = 1` and additionally requires the scrubber's *pinch* to fail alongside its pan, which covers the drag that begins with one finger and becomes a pinch. The pinch takes the same pager hold a scrub does (`didChangeScrubbing:`), so nothing pages for its duration. **The scrubber's own pan is deliberately left uncapped** — capping it breaks the pinch-back-to-scrub handoff, and `WaveformUI/iOS/CLAUDE.md` carries why.

**The right time control shows the total duration, and a tap flips it to the minus-prefixed remaining** — the mac's behavior and its default, held by `PlayerDisplaySettings` (below). Every render path — the tick, a page at rest, a scrub — goes through `VibeRightTimeText` so they cannot disagree. `TrackPageTimeControl` keeps the label visually aligned inside a real 44pt control, so accessibility and hit testing use the same action surface. The target is wired per cell but the mode is one setting, so the handler repaints **every visible page**, not the tapped one.

**A settings change arrives from outside the card**, since the screen that makes it sits on the Playlist tab with this one minimized behind it: `VibeDisplaySettingsDidChangeNotification` lands on `displaySettingsDidChange`, which re-configures every visible page (the header's codec line), syncs each page's waveform style, and repaints the times. It re-reads all three rather than being told which moved. A cell in the reuse pool needs none of it — it is configured from scratch on its way back on screen, and `willDisplayCell:` re-applies the zoom and the style there.

**The time labels belong to a scrub while one is running.** `didScrubToProgress:` arrives per frame of scroll and `+Delivery` renders it as the time the release will land on, guarded to whole seconds so a drag does not format strings at display rate; `updatePlaybackUI` bails outright on `isScrubbing` rather than fighting it. The duration falls back to the track's own, as the seek path does, so scrubbing a *parked* track — which is how one gets opened at a position — reads correctly too.

**The waveform zoom is one value for the whole pager**, since every cell carries its own scrubber and a swipe must not change it. `+Delivery`'s `didChangeVisibleFraction:` stores it, fans it out to the visible cells, and persists it to `VibeiOSWaveformZoom` — an iOS-owned key beside `FolderSession`'s, for the same reason; `+Pager` re-applies it on every `willDisplayCell:`, since a recycled cell keeps whatever depth it was last shown at. **What is stored is the user's request, never what a view drew**: see `WaveformUI/iOS/CLAUDE.md` for why a launch in the shallower orientation would otherwise ruin it permanently.

### TrackPageCell

One full-screen page: blurred art plus the mac-style header, and the transport row — previous, play/pause, next — which rides the page rather than the chrome above it. Two constraint sets swapped on the cell's own aspect in `layoutSubviews` — portrait is the Apple Music-style centered card, landscape is the mac main window transplanted. Its geometry constants are private to the cell.

**The transport is always up**; only the empty state fades it (`chromeAlpha`). It used to hide while playing, on the theory that a screen tap was the pause control — the tap still is, everywhere off the waveform and the transport row, but it is no longer the only one. **Next is dimmed at the end of the playlist**, decided off the PAGE's own index rather than the playing one so the last page arrives already dimmed.

Two traps sit under that one dimmed button, and both are load-bearing:

- **The disabled look is drawn, not delegated.** A system-type button dims its own template image for the disabled state, so an alpha on top compounds — the glyph measured 52/255 over the card's backdrop instead of the half it asks for. `setGlyph:onButton:pointSize:` therefore installs a pre-tinted `AlwaysOriginal` image for `UIControlStateDisabled`, which opts out of the tinting the adjustment rides on and carries the alpha itself.
- **Hit-testing does NOT hand back a disabled button.** The touch falls through to whatever is behind it, which here is the card's tap-anywhere-to-pause — so tapping next at the end of the playlist *paused playback*. The fix is `TrackPageTransportView`, a class of its own for the row's container, declined as a whole in `gestureRecognizerShouldReceiveTouch:` alongside `UIControl` and `WaveformScrubberView`. A `UIControl` check alone cannot cover it.

**Portrait is four bands, and only one of them moves.** A fixed strip under the safe top holds the grabber pill the card's chrome draws; the **art band** takes everything left over, which makes it the band the screen's height lands in, with the card centered in it at 80% — the remaining 20% is its padding; the **label band** is fixed; and the waveform and transport hang off the *safe bottom*, the time row off the waveform.

**So the waveform sits at the same y on every page, and that is a layout guarantee, not a coincidence.** The label band's height is the worst case its labels can need: a two-line title, one line each for artist and codec.

**The one exception is that the codec line can leave the band entirely** — when the setting is off, or a track has no readout yet. It gives up its line *and* the gap above it, so the band tightens by the whole row instead of holding the height as slack. That is one setting across every page, so the guarantee still holds; what moves is the art above it.

Nothing else in the band can move its edges — not a two-line title, not a missing artist, not a shrunk-to-fit one — and nothing above the waveform can reach it anyway. All three labels shrink to fit their width rather than truncate.

**The labels ride centered in the band**, one gap for both seams, rather than each sitting in a reserved box: a one-line title in a two-line box put its slack on screen as a gap under the title. The two single-line labels do keep their line reserved, so a track with no artist lays out like one that has it. The art card is what gives at accessibility text sizes.

**TRAP: the art card's shadow path is restated from the card's OWN layout pass** (`TrackPageArtCardView`), not the cell's. The constraints that size it belong to the contentView, so the header metrics landing — or Dynamic Type, or anything else that moves the label band — resizes the card without the cell's `layoutSubviews` running again. Set from there, the shadow keeps the card's previous, larger size: a wide dark halo around the art that vanishes the moment a swipe recycles the cell, which is exactly what makes it look like a rendering glitch rather than a layout one. Landscape anchors this header to the top safe area as well as its safe leading edge; full-screen landscape has unsafe top insets on notched devices.

**The time row is pulled UP into the waveform view's bottom** (`kCellTimeWaveformOverlap`). The scrubber centers its envelope in its bounds and reserves headroom above and below it, so measuring the gap from the view's frame leaves the times looking stranded; the edge the eye measures against is the drawn waveform. It hangs off the waveform rather than sitting between waveform and transport, so tightening it cannot push the waveform down. Landscape keeps a plain gap: its strip is a third shorter and its transport rides the time row's centerline, so the same pull-up would put a glyph over the envelope.

**A page shows full-size art and nothing standing in for it** — the vinyl placeholder until it arrives, never the 128px thumbnail, which is fine under the blur but visibly soft in the art card and only buys a swap to sharp a moment later.

Making it arrive first is the **art window**, in `+Pager`: the current page and its immediate neighbors decode ahead and keep their art (`_artHeldPages`) up to a byte budget, so a swipe either way lands on art already in memory — **but a page with a live cell is never released**, since its image view pins the bitmap anyway and the discard would free nothing while leaving the page one reconfigure from dropping to the placeholder in view. `renderHeaderForTrack:` moves the window; a metadata delivery re-runs it, because until a track's metadata lands its art dispatch is a message to nil. **The commit path deliberately discards nothing**: the departing track is usually the page right beside the arriving one, and releasing it per commit made every swipe back re-read and re-decode the file.

**The blurred backdrop is a baked image, not a `UIVisualEffectView`** — see `Util/iOS/CLAUDE.md`.

### PageWaveformCoordinator

The pager's waveform bookkeeping between `AudioWaveformCache` and the cells: the cache runs one load at a time, and this owns which page it targets along with that page's URL, the latest snapshot per page for re-hydrating reloaded cells, and the complete set. Foundation-only and tested.

**Waveform deliveries carry the URL they were loaded for**, so a decode that outlives its retarget is dropped on the value rather than on the cancel having been observed in time — the app-wide staleness guarantee, and the reason `requestIndex:track:` records `_targetURL` beside `_targetIndex`. A page the pipeline already targets is left alone, since re-requesting on every cell reload would keep killing the decode. A matching terminal failure clears the target, settles the page's loading line, and lets the next request retry the same file; a stale failure is dropped on the URL too. The snapshot window prunes to a radius around the current page. BPM/key deliveries are not forwarded because analysis is macOS-only.

**The scroll hold (`held`) is the pager's frame budget.** A swipe is the one moment the main thread has nothing to spare, and both halves of this object were spending it:

- a **delivery** repaints a scrubber, which tears its baked envelope down and restarts a 60 Hz full-view path rebuild — and a decode delivers about ten times a second, so the bake never re-landed;
- a **request** cancels the one load the cache runs, so a swipe across N pages cancelled N decodes and finished none.

Held, deliveries are recorded but not forwarded, and requests are dropped. `+Pager` takes the hold for a user swipe, a visible programmatic page animation and a size transition, while a minimized page move snaps without one. It clears the swipe hold **before** `commitVisiblePage`, so the settled page's request gets through.

Every programmatic retarget renews a generation-stamped deadline, which covers UIKit never delivering its end callback: the deadline releases the hold *and* reissues the current page's dropped waveform request. The same hold pauses the playhead's display link (`updateScrollLinkState`).

## Building and verifying

```bash
make build-ios CONFIG=Debug     # exactly what CI's build-ios job runs
```

Use the **`vibe-debug` skill**'s "iOS: the simulator loop" section to launch, feed, screenshot and log the app. `launch-ios.sh` boots/installs/relaunches with audio silent by default (the mac's `--no-audio-hw --silent` flags work verbatim; the engine is shared), seeds audio into the container, and the log streams from the host.

**The debug command channel exists on iOS** (debug builds only): `debug-ios.sh <verb>` writes a command file into the simulator app's container tmp — a plain host directory, so no CLI client is needed — and the app's directory watcher answers with one JSON object, the same file protocol as the mac. The transport (`Vibe/Debug/DebugChannel.m`) is shared with the mac verbatim, and so is most of the verb set, written once in `Vibe/Debug/DebugCommonVerbs.m` against the `VibeDebugPlayerSurface` protocol.

**`RootViewController` is what adopts that protocol**, because it is the one object that can see the whole app: `RootViewController+Debug` composes the model's handles (`PlaybackController+Debug`) with the card's chrome and art window (`PlayerViewController+Debug`) and adds the shell's own state — which tab, whether the strip is up, whether the card is. What is left in `Vibe/Debug/iOS/DebugCommands.m` is only what needs UIKit, plus `expand_player`, `minimize_player` and `select_tab`, which exist because the channel cannot synthesize a touch. **All three debug categories live in `Vibe/Debug/iOS/`** — the shipping tree carries no declaration for a tool that does not ship, and `make check-vocabulary` enforces it.

The channel cannot inject touches (no public API synthesizes `UITouch`es in-process); **gestures go through the touch driver** — `drive-ios.sh` and the resident `VibeiOSDriver` XCUITest in `Tests/iOSDriver/`. Real-pixel screenshots stay `simctl io booted screenshot`; the channel's `dump_screenshot` is the in-process render.

**Interruptions, route changes, background audio past lock and the lock-screen card need a real device** — the simulator exercises none of them faithfully.

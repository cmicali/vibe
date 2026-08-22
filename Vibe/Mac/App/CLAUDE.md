# App (macOS)

The application object and the app-wide services it owns. The test for this directory is ownership: **`AppDelegate` creates it, or the OS hands it to `AppDelegate`.** A service used by several features but owned by none of them lives here; a service owned by one feature lives with that feature.

The bootstrap starts outside: `main.m` at the repo root creates the `AppDelegate` and keeps it alive in a global, because `NSApplication.delegate` is weak. `applicationWillFinishLaunching:` creates `MainPlayerController` and installs the menu bar through `MainMenuBuilder`. See `Mac/Menu/CLAUDE.md`.

`AppDelegate` also installs `NSURLUtil`'s handler blocks at launch — the playlist-grant handler and the two folder-art harvest handlers — which is how a path utility in `Vibe/Util/` reports what it saw without reaching into an app singleton behind a setting and a sandbox grant.

## Opening files is a funnel, not an event

Every way a file can arrive — a Finder double-click, `⌘O`, Open Recent, a drop on the window, argv — lands in `AppDelegate` and comes out as one playlist. Two pieces make that true, and they are two because the OS delivers opens in two different broken shapes. Both are tested.

- **`OpenBurstCoalescer`** — Launch Services splits a multi-file open across several `application:openURLs:` calls. The first batch plays immediately, because a double-clicked file must not wait out a delay; later batches inside a **0.3-second quiet period** are appended instead of replacing.
- **`OpenRequestCoordinator`** — expansion (the folder walk, the CUE/M3U read) runs concurrently, so results come back out of order. One instance serves the whole app, shared with the window's drop funnel. It buffers appends within the surviving burst and lets a newer **deliberate** replacement supersede every unfinished older result. An expansion that never finishes — a mount that stops answering — gives up after **ten seconds** and delivers anyway, or one wedged batch would swallow every later batch in its burst.

`⌘O`, Open Recent and window drops enter through `openDeliberateURLs:appending:` and bypass the burst, so a deliberate action ends a Launch Services burst in progress rather than joining it. Drops are the one deliberate open that carries its own append decision.

The walk itself is `NSURLUtil` (`Vibe/Util/`), on a four-wide queue, so an unreachable mount cannot hold every later open hostage and cannot spawn a thread per drop either.

`DocumentTypes` is **not** here — it is `Vibe/Common/`, since it reads the bundle and touches no AppKit, and both targets declare document types. The `⌘O` panel's filter and `DefaultAppRegistration` (`Mac/Settings/`) both read it, so the two cannot disagree about what a supported file is.

## Sandbox grants

`FolderAccessManager` is the bookmark store: resolve at launch, merge what an open or a drop grants, persist, and answer `canReadInsideDirectory:` for anything that wants to know before it touches the disk. It is here rather than in `Mac/Settings/` because that pane is only its *display* — the readers are the app delegate, the folder-art resolver and the main window.

**Asking is separate from storing.** The one path that raises a panel — the grant a playlist file needs for the folder its entries live in — is `FolderAccessManager+GrantPanel`, split out because it is a modal AppKit run loop that blocks a background worker until a human answers, and the only part of the manager a unit test can never reach. The rest is non-blocking and covered by `FolderAccessCoverageTests`.

**A row's state costs no I/O to know.** `grantedFolders` answers `VibeGrantedFolderState` per row — `Active`, `Restoring` or `Unavailable` — from the resolve the manager already did. **Never stat a row to decide that**: `viewForTableColumn:` runs on the main thread for every reload, and a dead path's mount can block a stat for an automounter timeout.

**TRAP: an unresolved stored bookmark is not authority.** A stored row is visible immediately but authorizes nothing until restoration has started its security scope. Folder art never probes a directory the app holds no *active* grant for — unasked-for background work must never raise a permission panel. `FolderAccessManagerDidChangeNotification` is what says a scope has settled.

**TRAP: inside the sandbox, both `NSHomeDirectory` and `NSHomeDirectoryForUser` answer with the container**, which silently turns the ~/Music rule into a test against a path no music sits under. `+realHomeDirectory` uses `getpwuid`, the documented way to the on-disk home.

**TRAP: coverage has two spellings and the callers need different ones** (`FolderAccessRules.h`). `path:isCoveredByAnyOf:` is case-**sensitive** and is the auto-add's duplicate check; `readablePath:isCoveredByAnyOf:` is case-**insensitive** and is what decides whether an open must wait for a grant — those URLs come straight off Launch Services rather than a canonicalized open, and over-matching there only costs a wait that was not needed.

**Every wait for a grant is deadlined at two seconds**, the launch drain's and each open's alike. Waiting is an optimization: proceeding without the grant merely risks an unreadable folder, which every open path handles, while waiting forever on a mount that never answers leaves the window in its launch grace with a blank header and no way out.

Restoration has three utility workers plus one user-initiated lane reserved for a queued grant an open is waiting on. Four concurrent launch bookmark resolutions is the ceiling, while a relevant grant does not sit behind unrelated blocked restores. When remembered grants nest, the most-specific sufficient one takes that lane; once an active grant covers each requested URL, a still-resolving overlapping parent no longer holds the open. It posts its change notification **coalesced to one per run-loop turn**, because it settles one bookmark at a time and each observer does real work; the user-driven add and remove post directly, so the pane redraws in the same turn as the click.

## Stats

`AppStats` lives in `Vibe/Common/` and counts for **both** platforms; this shell feeds it from `deliverExpandedURLs:` (the open funnel) and from the player events, and `applicationWillTerminate:` folds the in-progress listening run. See `Common/CLAUDE.md` for the store and for what the two platforms do differently about keeping a running clock honest.

The open sinks and the player-delegate transitions feed it. **`stop` and quit fire no delegate callback**, so `closeFile:` and `applicationWillTerminate:` flush by hand; that asymmetry is the whole reason the counters are not simply derived.

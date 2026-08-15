# App

The application object and the app-wide services it owns. The test for this directory is ownership: **`AppDelegate` creates it, or the OS hands it to `AppDelegate`.** A service used by several features but owned by none of them lives here; a service owned by one feature lives with that feature.

The bootstrap itself starts outside: `main.m` in the repo root, then `AppDelegate`, then `MainMenuBuilder` (`Vibe/Menu/`) and `MainPlayerController` (`Vibe/MainWindow/`). `Vibe/Menu/CLAUDE.md` covers the launch sequence.

## Opening files is a funnel, not an event

Every way a file can arrive — a Finder double-click, `⌘O`, Open Recent, a drop on the window, argv — lands in `AppDelegate` and comes out as one playlist. Three pieces make that true, and they are three because the OS delivers opens in three different broken shapes:

- **`OpenBurstCoalescer`** — Launch Services splits a multi-file open across several `application:openURLs:` calls. The first batch plays immediately, because a double-clicked file must not wait out a delay; later batches inside a 0.3-second quiet period are appended instead of replacing. Tested.
- **`OpenRequestCoordinator`** — expansion (the folder walk, the CUE/M3U read) runs concurrently, so results come back out of order. It buffers appends within the surviving burst and lets a newer deliberate replacement supersede every unfinished older result. An expansion that never finishes — a mount that stops answering — gives up after ten seconds and delivers anyway, or one wedged batch would swallow every later batch in its burst. Tested.
- **`DocumentTypes`** is no longer here — it is `Vibe/Common/`, since it reads the bundle and touches no AppKit, and both targets declare document types. The `⌘O` panel's filter and `DefaultAppRegistration` (`Vibe/Settings/`) still read it, so the two cannot disagree about what a "supported file" is.

The walk itself is `NSURLUtil` (`Vibe/Util/`), which is deliberately ignorant of all this: it reports what it saw through handler blocks that `AppDelegate` installs at launch.

## Sandbox grants

`FolderAccessManager` is the bookmark store: resolve at launch, merge what an open or a drop grants, persist, and answer `canReadInsideDirectory:` for anything that wants to know before it touches the disk. It is here rather than in `Vibe/Settings/` because the Settings pane is only its *display* — the readers are the app delegate, the folder-art resolver and the main window.

**Asking is separate from storing.** The one path that raises a panel — the grant a playlist file needs for the folder its entries live in — is `FolderAccessManager+GrantPanel`, split out because it is a modal AppKit run loop that blocks a background worker until a human answers, and the only part of the manager a unit test can never reach. The rest is non-blocking and covered by `FolderAccessCoverageTests`.

TRAP: **an unresolved stored bookmark is not authority.** Folder art never probes a directory the app holds no *active* grant for; see the root `CLAUDE.md` invariant. Unasked-for background work must never raise a permission panel.

## Stats

`AppStats` counts lifetime usage — files and folders opened, seconds played — in `NSUserDefaults`, and the Advanced settings pane reads it. The open sinks and the player-delegate transitions feed it. **`stop` and quit fire no delegate callback**, so `closeFile:` and `applicationWillTerminate:` flush by hand; that asymmetry is the whole reason the counters are not simply derived.

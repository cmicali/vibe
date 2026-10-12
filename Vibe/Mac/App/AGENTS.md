# App (macOS)

The application object and the app-wide services it owns. The test for this directory is ownership: **`AppDelegate` creates it, or the OS hands it to `AppDelegate`.** A service several features use but none owns lives here. A service one feature owns lives with that feature.

`main.m` creates the `AppDelegate` and holds it in a global, because `NSApplication.delegate` is weak. `applicationWillFinishLaunching:` installs the Links backend first, before the menu, the restore and any open, so a restored link row is a streaming placeholder from the start (`Loading/Net/AGENTS.md`). It then installs `FolderWalk`'s three handler blocks: the playlist-grant handler and the two folder-art harvest handlers. That is how the walk in `Vibe/Playlist/` reports what it saw without reaching into an app singleton. Last it creates `MainPlayerController` and the menu bar (`Mac/Menu/AGENTS.md`).

## Opening files is a funnel, not an event

Every way a file arrives lands in `AppDelegate` and comes out as one playlist: a Finder double-click, ⌘O, Open Recent, Open URL, a drop on the window, argv. The OS delivers opens in two broken shapes, so two tested pieces handle them.

- **`OpenBurstCoalescer`.** Launch Services splits a multi-file open across several `application:openURLs:` calls. The first batch plays at once, so a double-clicked file never waits. Later batches inside a **0.3-second quiet period** append instead of replacing.
- **`OpenRequestCoordinator`.** Expansion (the folder walk, the CUE and M3U reads) runs concurrently, so results finish out of order. One instance serves the whole app, the window's drops included. It buffers appends within the surviving burst. A newer replacing open supersedes every unfinished older result. An expansion that never finishes, such as one on a mount that stopped answering, holds a later finished batch at most **ten seconds** before it is abandoned. Otherwise one wedged batch would swallow every later batch in its burst. **A held request is never abandoned** (`holdRequest:`, `releaseRequest:`). Every open with links to resolve is held. Each link probe has its own deadline. The release gives the head a full ten seconds for its expansion.

⌘O, Open Recent and window drops enter through `openDeliberateURLs:appending:`. A deliberate open ends a Launch Services burst in progress rather than joining it. A drop is the one deliberate open that carries its own append decision.

**Close invalidates the open coordinator before it unloads the playlist**, so a pending walk or a buffered append cannot reopen files the user closed. A replacing open uses the same invalidation.

The walk is `FolderWalk` (`Vibe/Playlist/`) on a four-wide queue. An unreachable mount cannot hold every later open hostage, and a burst of drops cannot spawn a thread each.

`DocumentTypes` lives in `Vibe/Common/`, because both targets declare document types. It seeds the ⌘O panel's filter and `DefaultAppRegistration` (`Mac/Settings/`). The panel then widens its filter to every type registered for those filename extensions.

**TRAP: another app's type for an extension need not conform to ours.** Without the widening, a supported file can be grayed out, depending on which other apps are installed. The widening does not change the extensions the walk accepts.

## Open URL and links

**Open URL (⌘U, `openLink:`) is an `NSPanel` that `OpenLinkWindowController` builds.** `AppDelegate` owns the controller for the app's life. The controller builds the panel at each show and releases it at each close. The panel is not a sheet, so the player keeps working while it is up. It stays up when Vibe is not active (`hidesOnDeactivate` off), since a link is often copied from a browser. It takes the level of the About and Settings windows (`applyAuxiliaryWindowLevels`). Open is disabled while the field is blank (`VibeLinkTextIsBlank`). Return presses Open and never breaks the line. Nothing reads the pasteboard unless the user pastes.

**⌘W reaches the panel because the controller, its delegate, answers `closeFile:` ahead of the player.** The player's `closeFile:` would clear the playlist. `AppDelegate` forwards `closeFile:` and Close's validation to the controller when no window takes them. Every close ends in `windowWillClose:`, which cancels a resolve still running.

**A link opens down the same road as a dropped link** (`openInOrder:token:completion:`). `openLinkString:completion:` takes a replacing request at once, then resolves the link. A failure or a cancel finishes the request with no rows, so a loaded playlist stays. There is no alert. The header shows the failure as a notice (`showNotice:naming:`, `Mac/MainWindow/AGENTS.md`). Every newer open request ends a held notice (`beginOpenRequestAppending:fromURLs:`).

**A drop can hold web links.** What a drop holds and in what order it opens is `Loading/Net/AGENTS.md`'s (`VibeDropURLsOfItems`, `VibeDropOpenOrder`). The coalescer's sink sends a batch holding a link or a `.webloc` down the link road (`VibeDropHasLinks`). There the links resolve one at a time, in drop order. The files and the links' files then open as one open, in drop order. A link that fails drops out, and the rest still open.

- **The waveform shows its loading shimmer while a drop resolves** (`beginLinkResolveFeedbackAppending:`). An append over a shown track shows nothing, since that track stays. Every delivery ends the shimmer once no drop is resolving (`endLinkResolveFeedbackIfIdle`). It runs after the play, so a replacing open keeps the shimmer for its own open. A superseded drop ends it when its links settle, since nothing delivers for it.
- **Escape on the player window cancels every open still resolving** (`cancelLinkOpens`). So does a newer replacing open, Open URL's included. A cancelled open opens nothing, its files included, and the Open URL panel closes.

**The outgoing network entitlement is for Open URL alone** (`ENABLE_OUTGOING_NETWORK_CONNECTIONS`, `project.yml`). Nothing else in the mac app makes a request. App Transport Security allows plain http only on the local network (`NSAllowsLocalNetworking`). `VibeLinkURLAcceptance` draws the same line before any request. macOS 15 and later ask the user before the first request to a local host (`NSLocalNetworkUsageDescription`).

## Sandbox grants

`FolderAccessManager` is the bookmark store. It resolves at launch, merges what an open or a drop grants, persists, and answers `canReadInsideDirectory:` before anything touches the disk. It lives here because its readers are the app delegate, the folder-art resolver and the main window. The Files pane only displays it.

**Asking is separate from storing.** `FolderAccessManager+GrantPanel` is the one path that raises a panel: the grant a playlist file needs for the folder its entries live in. A playlist file grants that file alone, not the audio it names. The panel blocks a background expansion worker until a human answers. **Powerbox prompts must not stack, so it serializes on its own gate.** No unit test can reach it. The rest of the manager never blocks and is covered by `FolderAccessCoverageTests`.

**The auto-add hook is the open funnel** (`openURLsWithRestoredAccess:token:` calls `noteOpenedURLs:`). It bookmarks only directories outside an active grant and outside ~/Music, which the entitlement covers.

**A row's state costs no I/O to know.** `grantedFolders` answers a `VibeGrantedFolderState` per row (`Active`, `Restoring` or `Unavailable`) from the resolve the manager already did. **Never stat a row to decide it.** `viewForTableColumn:` runs on main for every reload, and a dead mount can block a stat for an automounter timeout.

**TRAP: launch resolution never mounts a volume or shows UI** (`NSURLBookmarkResolutionWithoutMounting | WithoutUI`). Nobody asked for it. A grant on a server that is not mounted fails at once and stays Unavailable until a launch finds the volume mounted. Without the flags the resolver tries the mount itself. That can raise a connect dialog at every launch and pin a restore lane for the automounter timeout.

**TRAP: an unresolved stored bookmark is not authority.** A stored row is visible at once but authorizes nothing until restoration has started its security scope. Folder art never probes a directory without an *active* grant, because unasked-for background work must never raise a permission panel. `FolderAccessManagerDidChangeNotification` says a scope has settled.

**TRAP: inside the sandbox, `NSHomeDirectory` and `NSHomeDirectoryForUser` both answer the container.** That silently turns the ~/Music rule into a test against a path no music sits under. `+realHomeDirectory` uses `getpwuid`, the documented way to the on-disk home.

**TRAP: coverage has two spellings, and the callers need different ones** (`FolderAccessRules.h`). `path:isCoveredByAnyOf:` is case-**sensitive**. It is the auto-add's duplicate check over canonical spellings. `readablePath:isCoveredByAnyOf:` is case-**insensitive**. It is the read test (`canReadInsideDirectory:`), and the same folding decides whether an open must wait for a grant. Those paths come straight off Launch Services, a pasteboard or a track URL. Under-matching them would walk a folder before its grant is restored, or refuse a readable one.

**Every wait for a grant has a two-second deadline**, the launch drain's and each open's alike. Waiting is an optimization. Going on without the grant only risks an unreadable folder, which every open path handles. Waiting forever on a mount that never answers would leave the window in its launch grace with a blank header.

Restoration runs three utility workers plus one user-initiated lane for a grant an open is waiting on (`VibeFolderAccessRestoreConcurrencyLimit`). So a relevant grant never sits behind unrelated blocked restores. When remembered grants nest, the most specific sufficient one takes that lane. Once an active grant covers each requested URL, a parent still resolving no longer holds the open. Restoration posts its change notification **coalesced to one per run-loop turn**, because it settles one bookmark at a time and each observer does real work. The user's add and remove post directly, so the pane redraws in the same turn as the click.

## Updates

**The direct download updates itself through Sparkle. The Mac App Store build has no updater at all.** `VIBE_DIRECT_DISTRIBUTION` (`project.yml`) is the one channel marker: 1 in Debug and Release, 0 in `AppStore`. Nothing else may infer the channel. Everything Sparkle is inside `#if VIBE_DIRECT_DISTRIBUTION`: the import, the controller, the menu item, the two Settings rows, the beta setting and the debug report's feed line. The `AppStore` configuration also unlinks the framework and strips its Info.plist keys. `release-appstore.sh` and CI check the result (the `vibe-release` skill).

`AppDelegate` owns one `SPUStandardUpdaterController`. It is created unstarted in `applicationWillFinishLaunching:`, before the menu, and started in `applicationDidFinishLaunching:` after the window is up. `AppDelegate+Updates` creates it. That category is also the updater's delegate, and it holds `updateCheckInterval`. Sparkle's standard UI does the rest. Automatic checks are on from the first launch, weekly, so Sparkle never shows its first-run prompt (`SUEnableAutomaticChecks`, `SUScheduledCheckInterval`). Vibe adds three things.

- **Check for Updates…** targets the controller, which validates it.
- `allowedChannelsForUpdater:` adds the feed's `beta` channel while `AppSettings.receiveBetaUpdates` is on. Sparkle asks at every check, so the setting needs no live effect.
- Settings > General's **Check for updates** sets `updateCheckInterval`. Never turns automatic checks off. The other choices set the interval. Sparkle stores the choice over the Info.plist defaults.

**A Debug build starts no updater** unless launched with `--update-feed <url>`, which `feedURLStringForUpdater:` then answers. So the debug channel, stress runs and screenshots never raise an update dialog. Without it the menu item is disabled.

**The app stays sandboxed.** Sparkle's installer runs as its XPC service (`SUEnableInstallerLauncherService`). `Vibe-Direct.entitlements` adds the two mach-lookup exceptions for the installer's connection. App Review rejects temporary exceptions, so the `AppStore` configuration signs with `Vibe.entitlements`.

**TRAP: a local build runs without the hardened runtime.** Under it, library validation refuses an ad-hoc-signed Sparkle in an ad-hoc-signed app, and the app dies at launch with "different Team IDs". `asc_archive` turns it back on for every archive, and the Developer ID export signs both under one team.

Sparkle's dialogs use its own translations. It ships none for Bulgarian or Indonesian, so those users see its dialogs in English.

## The last playlist

**Launch order is grants, then drain, then restore, then the empty state.** Inside `restoreGrantedAccessWithCompletion:`, the tested `OpenBurstCoalescer.finishLaunchRestoring:revealEmpty:` calls `startAndDrainQueue` first. Only when nothing drained does `MainPlayerController.restoreLastPlaylist` run, and on the first launch only `loadWelcomeTrack` after it. Only when both find nothing does `revealEmptyStateNamingPlaylist:nil` end the launch grace (`Mac/MainWindow/AGENTS.md`).

**A launch-time open outranks the remembered playlist, and the restore is not an open.** It does not enter the coalescer. An empty drain arms no burst, so a Finder open a beat later replaces rather than appends. It does not enter `openURLs:appending:` either, so it records no stats and mints no bookmarks.

`MainPlayerController` saves and restores the mirror through `PlaylistFile+Session` (`Playlist/Mac/`). The mirror's rules are in `Mac/MainWindow/AGENTS.md` (The last playlist).

**Links are pruned once per launch, after the restore** (`pruneLinks`). The playlist's rows and the recent documents keep their links (`pruneKeepingTracks:recentURLs:`). The store deletes every other link not opened for 30 days, off main. A launch-time open may still be expanding, so its rows keep nothing. A saved M3U naming a pruned link finds that entry missing.

`AppStats` (`Vibe/Common/`, `Common/AGENTS.md`) counts on both platforms. This shell feeds it from `deliverExpandedRows:` and from the player's output-audio activity event.

## Quitting

**A quit leaves the screen first and finishes afterwards.** `applicationShouldTerminate:` orders out every window and drops the Dock tile and menu bar (`NSApplicationActivationPolicyProhibited`). It detaches the player's delegate, so nothing auto-advances. Then it waits off main for what a quit owes: `AudioPlayer.prepareForTermination`, and a conversion's cancel. `prepareForTermination` puts a bit-perfect device's format back and releases its hog, which waits on the device (about 0.2 s on a USB DAC, bounded at 1.5 s). `applicationWillTerminate:` then only flushes stats and calls `saveLastPlaylist`.

**The app does not opt into sudden termination.** Under it an idle quit is a SIGKILL with no callback, and the last playlist would not be written.

**TRAP: the reply goes through the main run loop's block queue (`CFRunLoopPerformBlock`), never the main dispatch queue.** A quit issued from inside a main-queue block (the debug channel's `quit`, anything dispatched to main) runs `terminate:`'s wait loop inside that block. libdispatch does not drain the main queue re-entrantly, so a reply queued there never runs, and Vibe sits hidden and never exits. The converter's settlement, which the quit waits on mid-encode, uses the same queue for the same reason (`Audio/Mac/Convert/AGENTS.md`).

## Debug info

`DebugInfo` is the report behind Settings > Advanced > Save Debug Info. The debug channel's `dump_debug_info` returns the same text. **It is passive.** It reads and changes nothing, so it is safe to save in the middle of the problem it describes.

It is two calls because of two threads. `VibeDebugInfoSnapshot` reads on main what only main may read: the controller, the windows, every stored setting. It reads `position`, which never waits on the player queue. `VibeDebugInfoText` does the slow part off main. It collects the log, then allows two seconds each for the hardware, player and audio-path sections. A section that times out reports its cached value with its capture time, or unavailable. Each section allows one outstanding worker across all exports, so a hung driver cannot pile up workers. `block_player` is a debug-only fault for testing the export during a queue stall.

- **Settings are the whole stored domain, not a curated list**, so a new setting is reported without anyone adding it. **Data values are reported by size only.** A security-scoped bookmark would otherwise put an access grant into a file meant for sharing.
- **The log is all of Vibe's own lines, the audio frameworks' lines at any stored level, and anyone's errors**, capped at the newest 100,000 lines. Device trouble is reported in the frameworks' lines. Without `VIBE_VERBOSE_LOGGING` (root `AGENTS.md`), Vibe's info and debug lines were never stored, and the report cannot recover them.
- **It covers this run only.** The log store is scoped to the current process, so a user must save before quitting.
- **The audio path** (`audioPath`) is the render chain stage by stage, from source file to output device. Settings > Advanced's Audio group and the debug channel's `dump_audio_path` read the same model.

## The Dock tile

**`NSDockTile+Util`**: the Dock tile and the app icon behind it.
- `setDockIcon:shaped:` composes artwork onto the icon grid off main. With the theme's App icon shape off, it installs the picture as it is.
- `setAppIcon:shaped:` composes a theme's custom icon the same way into `NSApp.applicationIconImage`, so the Dock, the app switcher and the About surfaces agree. Nil resets to the bundle icon.
- `resetToAppIcon` puts the application's icon back in the tile. It reads the icon live, so a custom icon shows through.
- The file's `TRAP:`s are the authority. One view is installed for good and only its image swaps, since detaching and re-installing a view leaks a 256KB dock-tile context per transition. Assigning `applicationIconImage` replaces the tile's content view, so every install re-attaches ours. **Each custom-icon-then-reset round trip of `applicationIconImage` also leaks one 256KB context inside AppKit's setter**, so `setAppIcon:shaped:` assigns only on a change.

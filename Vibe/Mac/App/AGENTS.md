# App (macOS)

The application object and the app-wide services it owns. The test for this directory is ownership: **`AppDelegate` creates it, or the OS hands it to `AppDelegate`.** A service several features use but none owns lives here. A service one feature owns lives with that feature.

`main.m` creates the `AppDelegate` and holds it in a global, because `NSApplication.delegate` is weak. `applicationWillFinishLaunching:` installs the Links backend first, before the menu, the restore and any open, so a restored link row is a streaming placeholder from the start (`Loading/Net/AGENTS.md`). It then installs `FolderWalk`'s four handler blocks: the playlist-grant handler and the three folder-art harvest handlers. The walked-file handler ranks each file by folder art's cover rank. That is how the walk in `Vibe/Playlist/` reports what it saw without reaching into an app singleton. Last it creates `MainPlayerController` and the menu bar (`Mac/Menu/AGENTS.md`).

**Launch work the first window does not need runs half a second after the window is up** (`VibeAfterLaunch`). The menu's key equivalents and the link prune run there. A main-queue block queued during launch can still run before the window, so `dispatch_async` is not enough.

## Opening files is a funnel, not an event

Every way a file arrives lands in `AppDelegate` and comes out as one playlist: a Finder double-click, ⌘O, Add to Playlist, Open Recent, Open URL, a drop on the window, argv. The OS delivers opens in two broken shapes, so two tested pieces handle them.

- **`OpenBurstCoalescer`.** Launch Services splits a multi-file open across several `application:openURLs:` calls. The first batch plays at once, so a double-clicked file never waits. Later batches inside a **0.3-second quiet period** append instead of replacing.
- **`OpenRequestCoordinator`.** Expansion (the folder walk, the CUE and M3U reads) runs concurrently, so results finish out of order. One instance serves the whole app, the window's drops included. It buffers appends within the surviving burst. A newer replacing open supersedes every unfinished older result. An expansion that never finishes, such as one on a mount that stopped answering, holds a later finished batch at most **ten seconds** before it is abandoned. Otherwise one wedged batch would swallow every later batch in its burst. **A held request is never abandoned** (`holdRequest:`, `releaseRequest:`). Every open with links to resolve is held. Each link probe has its own deadline. The release gives the head a full ten seconds for its expansion.

⌘O, Add to Playlist, Open Recent and window drops enter through `openDeliberateURLs:appending:`. A deliberate open ends a Launch Services burst in progress rather than joining it. Add to Playlist and a drop are the deliberate opens that can append. **⌘O and Add to Playlist share one open panel.** Choosing either command with the panel open brings it forward. The command chosen last sets its button and whether it appends.

**Close invalidates the open coordinator before it unloads the playlist**, so a pending walk or a buffered append cannot reopen files the user closed. A replacing open uses the same invalidation.

The walk is `FolderWalk` (vibe-libs' `media/FolderScan`) on a four-wide queue. An unreachable mount cannot hold every later open hostage, and a burst of drops cannot spawn a thread each.

`DocumentTypes` lives in `Vibe/Common/`, because both targets declare document types. It seeds the ⌘O panel's filter and `DefaultAppRegistration` (`Mac/Settings/`). The panel then widens its filter to every type registered for those filename extensions.

**TRAP: another app's type for an extension need not conform to ours.** Without the widening, a supported file can be grayed out, depending on which other apps are installed. The widening does not change the extensions the walk accepts.

## Open URL and links

**Open URL (File > Open Location…, ⌘L, `openLink:`) is an `NSPanel` that `OpenLinkWindowController` builds.** `AppDelegate` owns the controller for the app's life. The controller builds the panel at each show and releases it at each close. The panel is not a sheet, so the player keeps working while it is up. It stays up when Vibe is not active (`hidesOnDeactivate` off), since a link is often copied from a browser. It takes the level of the About and Settings windows (`applyAuxiliaryWindowLevels`). Open is disabled while the field is blank (`VibeLinkTextIsBlank`). Return presses Open and never breaks the line. Nothing reads the pasteboard unless the user pastes.

**⌘W reaches the panel because the controller, its delegate, answers `closeFile:` ahead of the player.** The player's `closeFile:` would clear the playlist. `AppDelegate` forwards `closeFile:` and Close's validation to the controller when no window takes them. Every close ends in `windowWillClose:`, which cancels a resolve still running.

**A link opens down the same road as a dropped link** (`openInOrder:token:completion:`). `openLinkString:completion:` takes a replacing request at once, then resolves the link. A failure or a cancel finishes the request with no rows, so a loaded playlist stays. There is no alert. The header shows the failure as a notice (`showNotice:naming:`, `Mac/MainWindow/AGENTS.md`). Every newer open request ends a held notice (`beginOpenRequestAppending:fromURLs:`).

**A drop can hold web links.** What a drop holds and in what order it opens is vibe-libs' `files/ShareLinks/AGENTS.md`'s (`VibeDropURLsOfItems`, `VibeDropOpenOrder`). The coalescer's sink sends a batch holding a link or a `.webloc` down the link road (`VibeDropHasLinks`). There the links resolve one at a time, in drop order. The files and the links' files then open as one open, in drop order. A link that fails drops out, and the rest still open.

- **The waveform shows its loading shimmer while a drop resolves** (`beginLinkResolveFeedbackAppending:`). An append over a shown track shows nothing, since that track stays. Every delivery ends the shimmer once no drop is resolving (`endLinkResolveFeedbackIfIdle`). It runs after the play, so a replacing open keeps the shimmer for its own open. A superseded drop ends it when its links settle, since nothing delivers for it.
- **Escape on the player window cancels every open still resolving** (`cancelLinkOpens`). So does a newer replacing open, Open URL's included. A cancelled open opens nothing, its files included, and the Open URL panel closes.

**Open URL uses the outgoing network entitlement** (`ENABLE_OUTGOING_NETWORK_CONNECTIONS`, `project.yml`) in every macOS configuration. App Transport Security allows plain http only on the local network (`NSAllowsLocalNetworking`). `VibeLinkURLAcceptance` draws the same line before any request. macOS 15 and later ask the user before the first request to a local host (`NSLocalNetworkUsageDescription`).

## Sandbox grants

The folder grants' store is vibe-libs' `files/SandboxAccess` (`FolderAccessManager`). Its doc holds the store's rules and traps: launch resolution never mounts a volume, an unresolved bookmark is not authority, coverage's two spellings, the on-disk home, the two-second deadlines, and the restore lanes. This section is Vibe's side.

**The app delegate makes the one store at init** (`folderAccessManager`), over the standard defaults and the key `VibeGrantedFolders`. **TRAP: that key is shipped.** Another spelling forgets every grant. The Files pane and the debug info report read the store from the app delegate. The launch providers capture it.

**The auto-add hook is the open funnel** (`openURLsWithRestoredAccess:token:` calls `noteOpenedURLs:`). Each open first waits for the grants that cover it (`awaitRestoredAccessForURLs:completion:`). The store bookmarks only directories outside an active grant and outside ~/Music, which Vibe's music entitlement covers.

**The grant panel is the folder walk's playlist handler**, installed in `applicationWillFinishLaunching:`. A playlist file grants that file alone, not the audio it names, so the walk asks for the folder its entries live in. The handler formats the panel's message from the app's name and the playlist's file name, and passes Vibe's strings.

**Folder art reads the store through its access provider** (`canReadInsideDirectory:`), so it never probes a directory without an *active* grant. `MainPlayerController` observes `FolderAccessManagerDidChangeNotification` for it (`Mac/MainWindow/AGENTS.md`). The Files pane only displays the store (`Mac/Settings/AGENTS.md`).

## Updates

**The direct download updates itself through Sparkle. The Mac App Store build has no updater at all.** `VIBE_DIRECT_DISTRIBUTION` (`project.yml`) is the one channel marker: 1 in Debug and Release, 0 in `AppStore`. Nothing else may infer the channel. Everything Sparkle is inside `#if VIBE_DIRECT_DISTRIBUTION`: the import, the controller, the menu item, the two Settings rows, the beta setting and the debug report's feed line. The `AppStore` configuration also unlinks the framework and strips its Info.plist keys. `release-appstore.sh` and CI check the result (the `vibe-release` skill).

`AppDelegate` owns one `SPUStandardUpdaterController`. It is created unstarted in `applicationWillFinishLaunching:`, before the menu, and started in `applicationDidFinishLaunching:` after the window is up. `AppDelegate+Updates` creates it. That category is also the updater's delegate, and it holds `updateCheckInterval`. Sparkle's standard UI does the rest. Automatic checks are on from the first launch, daily. Sparkle then never shows its first-run prompt (`SUEnableAutomaticChecks`, `SUScheduledCheckInterval`). Vibe adds four things.

- **Check for Updates…** targets the controller, which validates it.
- `allowedChannelsForUpdater:` adds the feed's `beta` channel while `AppSettings.receiveBetaUpdates` is on. Sparkle asks at every check, so the setting needs no live effect.
- Settings > General's **Automatically check for updates** switch writes `updateCheckInterval`. Off turns Sparkle's automatic checks off. On turns them on at the daily interval, unless a longer one is stored. The getter reads Sparkle's own store and answers 0 while automatic checks are off. **Check for updates now** sends `checkForUpdates:` to the controller, as the menu item does.
- `feedParametersForUpdater:` appends the macOS version, the running architecture, the update channel, and the app's language to the feed URL at every check. Sparkle's User-Agent already names the app version. It adds `d=1`, `w=1`, or `m=1` on the copy's first check in a UTC day, ISO week, or month. It compares each period with the one saved in user defaults. `updater:didFinishLoadingAppcast:` saves all three, so a check that fails offline uses up no period. The site counts the checks (`Assets/Web/README.md`, Update checks). The privacy policy names every key. A new key needs a policy change in the same commit.

**A Debug build creates the updater but does not start it** unless launched with `--update-feed <url>`, which `feedURLStringForUpdater:` then answers (`startUpdaterIfConfigured`). So the debug channel, stress runs and screenshots never raise an update dialog. An unstarted updater still stores the interval and the automatic-check flag, and `checkForUpdates:` on it does nothing. So Settings > General's Updates rows stay live to test, and the menu item validates as disabled.

**The app stays sandboxed.** Sparkle's installer runs as its XPC service (`SUEnableInstallerLauncherService`). `Vibe-Direct.entitlements` adds the two mach-lookup exceptions for the installer's connection. App Review rejects temporary exceptions, so the `AppStore` configuration signs with `Vibe.entitlements`.

**TRAP: a local build runs without the hardened runtime.** Under it, library validation refuses an ad-hoc-signed Sparkle in an ad-hoc-signed app, and the app dies at launch with "different Team IDs". `asc_archive` turns it back on for every archive, and the Developer ID export signs both under one team.

Sparkle's dialogs use its own translations. It ships none for Bulgarian or Indonesian, so those users see its dialogs in English.

## The last playlist

**Launch order is grants, then drain, then restore, then the empty state.** Inside `restoreGrantedAccessWithCompletion:`, the tested `OpenBurstCoalescer.finishLaunchRestoring:revealEmpty:` calls `startAndDrainQueue` first. Only when nothing drained does `MainPlayerController.restoreLastPlaylist` run, and `loadWelcomeTrack` after it, which parks nothing once the user has played or opened something. Only when both find nothing does `revealEmptyStateNamingPlaylist:nil` end the launch grace (`Mac/MainWindow/AGENTS.md`).

**A launch-time open outranks the remembered playlist, and the restore is not an open.** It does not enter the coalescer. An empty drain arms no burst, so a Finder open a beat later replaces rather than appends. It does not enter `openURLs:appending:` either, so it records no stats and mints no bookmarks.

`MainPlayerController` saves and restores the mirror through `PlaylistFile+Session` (`Playlist/Mac/`). The mirror's rules are in `Mac/MainWindow/AGENTS.md` (The last playlist).

**Links are pruned once per launch, half a second after the restore** (`pruneLinks`). The playlist's rows and the recent documents keep their links (`pruneKeepingTracks:recentURLs:`). The store deletes every other link not opened for 30 days, off main. A launch-time open may still be expanding, so its rows keep nothing. A saved M3U naming a pruned link finds that entry missing.

`AppStats` (`Vibe/Common/`, `Common/AGENTS.md`) counts on both platforms. This shell feeds it from `deliverExpandedRows:` and from the player's output-audio activity event.

## Quitting

**A quit leaves the screen first and finishes afterwards.** `applicationShouldTerminate:` orders out every window and drops the Dock tile and menu bar (`NSApplicationActivationPolicyProhibited`). It detaches the player's delegate, so nothing auto-advances. Then it waits off main for what a quit owes: `AudioPlayer.prepareForTermination`, and a conversion's cancel. `prepareForTermination` puts a bit-perfect device's format back and releases its hog, which waits on the device. Format confirmation polls for up to 1.5 s. Individual HAL calls can block beyond that deadline. `applicationWillTerminate:` then only flushes stats and calls `saveLastPlaylist`.

**The app does not opt into sudden termination.** Under it an idle quit is a SIGKILL with no callback, and the last playlist would not be written.

**TRAP: the reply goes through the main run loop's block queue (`CFRunLoopPerformBlock`), never the main dispatch queue.** A quit issued from inside a main-queue block (the debug channel's `quit`, anything dispatched to main) runs `terminate:`'s wait loop inside that block. libdispatch does not drain the main queue re-entrantly, so a reply queued there never runs, and Vibe sits hidden and never exits. The converter's settlement, which the quit waits on mid-encode, uses the same queue for the same reason (`Mac/Convert/AGENTS.md`).

## Debug info

`DebugInfo` is the report behind Settings > Advanced > Save Debug Info. The debug channel's `dump_debug_info` returns the same text. **It is passive.** It collects diagnostics without changing playback or settings.

It is two calls because of two threads. `VibeDebugInfoSnapshot` reads on main what only main may read: the controller, the windows, every stored setting. It reads `position`, which never waits on the player queue. `VibeDebugInfoText` does the slow part off main. It collects the log, then allows two seconds each for the hardware, player and audio-path sections. A section that times out reports its cached value with its capture time, or unavailable. Each section allows one outstanding worker across all exports, so a hung driver cannot pile up workers. `block_player` is a debug-only fault for testing the export during a queue stall.

- **Settings are the whole stored domain, not a curated list**, so a new setting is reported without anyone adding it. **Data values are reported by size only.** A security-scoped bookmark would otherwise put an access grant into a file meant for sharing.
- **The log is all of Vibe's own lines, the audio frameworks' lines at any stored level, and anyone's errors**, capped at the newest 100,000 lines. Device trouble is reported in the frameworks' lines. Without `VIBE_VERBOSE_LOGGING` (root `AGENTS.md`), Vibe's info and debug lines were never stored, and the report cannot recover them.
- **It covers this run only.** The log store is scoped to the current process, so a user must save before quitting.
- **The audio path** (`audioPath`) is the render chain stage by stage, from source file to output device. Settings > Advanced's Audio group and the debug channel's `dump_audio_path` read the same model.

## The Dock tile

**`NSDockTile+Util`**: the Dock tile and the app icon behind it.
- `setDockIcon:shaped:` composes artwork onto the icon grid off main. With the theme's App icon shape off, it installs the picture as it is.
- `setAppIcon:shaped:` composes a theme's custom icon synchronously on main and assigns `NSApp.applicationIconImage`. The Dock, app switcher and About surfaces read that image. Nil resets to the bundle icon.
- `resetToAppIcon` puts the application's icon back in the tile. It reads the icon live, so a custom icon shows through.
- The file's `TRAP:`s are the authority. One view is installed for good and only its image swaps, since detaching and re-installing a view leaks a 256KB dock-tile context per transition. Assigning `applicationIconImage` replaces the tile's content view, so every install re-attaches ours. **Each custom-icon-then-reset round trip of `applicationIconImage` also leaks one 256KB context inside AppKit's setter**, so `setAppIcon:shaped:` assigns only on a change.

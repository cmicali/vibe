# System

Bridges to OS services that are neither the audio engine nor the app's UI. Both platforms drive everything here, and nothing here knows which one it is talking to beyond a `TARGET_OS_OSX` guard around an API that genuinely differs.

Three residents, and the bar is the test all of them pass: **it talks to the system on the app's behalf, it holds no playback state of its own, and both targets need it.** Something only one platform can use belongs in that platform's directory; something with no OS service behind it is `Util/`.

## NowPlayingController

The `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` bridge: publishing what is playing, and receiving hardware transport commands back. It owns no playback state — its driver hands it track and timing updates and takes the commands back through the delegate, routing them to the same transport entry points the on-screen buttons use. `MainPlayerController+NowPlaying` is that driver on macOS, `PlaybackController+NowPlaying` on iOS.

**Shuffle and repeat are commands, not Now Playing info.** `changeShuffleModeCommand` and `changeRepeatModeCommand` take the system's controls (Siri, the Watch, accessories) to the delegate's `setShuffleEnabled:` and `setRepeatMode:`, which write the setting and apply it exactly as the app's own control does; the state the system shows is `currentShuffleType` and `currentRepeatType` on the commands, written by `updateShuffleEnabled:repeatMode:available:` wherever a shell applies the modes, so a change from anywhere reaches it. A shuffle request of Items or Collections is on: there is no album-level shuffle. `available` sets both commands' `enabled`: the mac always passes YES; iOS passes the card's Show shuffle and repeat, so CarPlay hides its buttons with the card's, and writes any request that still arrives back as off (`iOS/Settings/AGENTS.md`).

**TRAP: the command center is process-global — lock screen, Control Center, CarPlay, AirPods and the mac's media keys share it — and the system picks which enabled commands fill the compact transport.** The shuffle and repeat pair leaves next/previous in place — the iPhone lock screen and both platforms' Control Center draw no shuffle or repeat at all, the mac's media keys and AirPods taps still skip, and Siri reaches the pair — but the skip-interval pair `docs/future/carplay.md` weighs takes their place. Check any further command on a device first.

`MPNowPlayingInfoCenter.playbackState` is the one macOS-only write (the property does not exist on iOS, which derives state from the audio session and the published rate) and it is guarded.

`initWithClock:publish:commandAvailability:` runs the same publication path without registering remote commands. Host-less tests inject the clock and OS writes to cover first-play gating, clearing, dirty detection, command changes and artwork promotion; actual system registration remains a live-app check.

The republish rules are header-only in `NowPlayingRules.h`, tested, on this side of the platform boundary because both platforms publish through them; the iOS widget publisher shares its string comparison.

**TRAP: the published artwork must be privately rasterized on the main thread, and that result must be the only thing the `MPMediaItemArtwork` request handler hands back.** The handler runs on MediaPlayer's threads, and the source is the live `NSImage` the UI is drawing; `NSImage` is not safe to draw from two threads at once. `VibeArtworkForPublishing` always redraws, even a small thumbnail, caps art at 512px, and hands over a private copy (macOS; iOS passes the image through).

**A track with no decoded art publishes the shell's placeholder**, which the driver hands in as `placeholderArt:` because only the shell knows it: the current theme's `defaultArtworkImageForAppearance:` for the main window's effective appearance on macOS — Vibe's own light/dark choice, its Settings preview or a single-mode theme's pin, not the system's, since the rasterization runs where the drawing appearance is the system's — and `record-bg` (the pager's) on iOS. It goes through the same rasterization. The dirty check compares identity and each side is one cached image, so a theme change or a window appearance flip republishes (the window's appearance hook calls `updateNowPlaying`) and nothing else does.

**TRAP: the debug-only `--no-audio-hw` and `--no-now-playing` flags suppress all of it** — no publish, no command registration — because publishing can pull AirPods from another device even when rendering to a virtual output. `--no-now-playing` leaves hardware rendering enabled for loopback tests (`VIBE_NOW_PLAYING=0` in the launcher). Verifying this class needs a launch without either flag; under either one `dump_now_playing` reports `hasInfo: 0`. See the `vibe-debug` skill.

**Nothing is published until the first track plays.** `updateWithTrack:…` withholds every publish before its first Playing one — a nil track, a parked or paused start alike — so an app launching into a restored session cannot claim the system slot; next/previous command availability is applied before that return regardless. After the first play a nil track clears the slot once.

## DownloadProgressMonitor

Best-effort download progress for a cloud file being materialized by its file provider, feeding the waveform's loading indicator on both platforms: shimmer while indeterminate, determinate fill when a fraction is known. Main thread only, like the delegate paths it feeds. **It observes and must never trigger a download** — the player's open is what actually fetches.

**`+monitorReplacing:forURL:currentURL:movement:handler:` is how a screen starts one.** A monitor outlives fast track changes, so a late sample would paint the wrong track's bar. The class method cancels the outgoing monitor, starts the new one, and drops any fraction whose URL is no longer what `currentURL` answers; the two-step init/start it wraps is private to the class. Both shells call it from their `+PlayerEvents`, while preserving it when a same-row replay still owns the same underlying open identifier, and declare the file to `CloudTransferRegistry` first, releasing it in their one `teardownDownloadMonitor` (`Audio/Loading/AGENTS.md`).

Three sources, best wins. Everywhere: a poll of the dataless file's allocated size against its logical size, plus an iCloud `NSMetadataQuery` when the item is in iCloud's index. macOS also has the File Provider `NSProgress` publication, exact when the provider publishes and superseding the poll. iOS has no consumer-side progress API for third-party providers, so those files have only the poll — the header records why, so nobody re-researches it.

`DownloadProgressMonitor` owns only source precedence, movement and whole-percent coalescing. The private classes in `DownloadProgressSourceAdapters` each own one system lifecycle — timer, metadata query or File Provider subscription/KVO — including its complete cancellation path. A new observation mechanism belongs behind the same fraction callback instead of adding another lifecycle to the monitor.

`DownloadProgressSourceAdaptersInternal.h` narrows the host-less boundary to iCloud query construction/ubiquity lookup and File Provider subscriber registration. The tests still drive the production notification, filtering, KVO, replacement, unpublish and cancellation paths; only the OS finding a cross-process publication remains a live-app check.

An `NSProgress` unpublish is not completion: it also covers an abandoned operation or a disappearing provider. It detaches that exact source and lets the poll verify the file; only a reported 100% or materialized filesystem state publishes completion.

The UI fraction remains whole-percent coalesced, but transfer liveness is not. Only a finite, strictly positive raw increase is movement; initial zero, repeated, backward, negative and NaN samples never extend the player's deadline. The fake source passes zero through the same rule rather than silently hiding the provider's initial-value shape.

Both of those decisions are `DownloadProgressRules.h`, header-only and tested: `VibeDownloadProgressIsMovement` is the liveness half, and `VibeDownloadPollShouldPublish` is the poll's — the two-part dataless-and-blocks test below.

**A clear `SF_DATALESS` and the allocated blocks must both say the file is here.** Every measured provider flags its placeholders (Dropbox on both platforms, iCloud Drive); the second half guards one that would not, which would otherwise read a download not yet begun as a motionless 100%. With no positive fraction the monitor reports nothing at all rather than a zero.

**TRAP: `NSURLIsUbiquitousItemKey` is not an iCloud test.** Every File Provider item answers YES to it — a Dropbox file included — so it only gets as far as "some cloud". The `NSMetadataQuery` is what settles it, and it stops on an item iCloud does not index rather than idling for the length of the download.

`Vibe/Debug/VibeFakeCloud` stands in for the provider's reporting too, and its seam **replaces** the sources above rather than joining them: under a fake transfer the file on disk is genuinely local, so the poll would answer a final 100% on its first tick. `DownloadProgressMonitor+Debug.h` carries the whole rule.

## CloudFileMaterializer

Pulls a file provider's placeholder down to disk as an explicit, **abortable** step, for background work that needs a cloud file's bytes and must be able to stop wanting them. Background only — it blocks for a transfer, and coordinating on main is how an app deadlocks against its own presenters.

It exists because an ordinary read cannot be interrupted. Opening a dataless file — TagLib's read, `AudioFileHandle`'s open — blocks in the kernel until the provider finishes, whatever the app decides meanwhile. `NSFileCoordinator`'s `-cancel` is the one documented way out ("any current invocation will stop waiting and return immediately", from any thread), which is why the download is coordinated here rather than left implicit inside whatever opens the file next.

Its sole production caller is `AudioFileMaterializationCoordinator` in `Vibe/Audio/`. That coordinator wraps each admitted path-wide run in a fresh materializer, while playback, prefetch and metadata attach role-bearing waiters to the one standardized-path claim. Consumers cancel their own request tokens; only the last waiter leaving, or a central metadata yield, reaches this primitive's cancel path. Neither the coordinator's handle-open stage nor `AudioTrackMetadataLoader` mints a materializer directly.

**Cancellation has exactly one spelling here**, `VibeMaterializationCancelledError` (`NSCocoaErrorDomain` / `NSUserCancelledError`, which is also what `NSFileCoordinator` returns for its own `-cancel`). Above this primitive, the central coordinator's result enum — Ready, Yielded, AdmissionExhausted or Failed — is the policy surface; callers do not infer retry behavior from this underlying error.

**Every transfer — the coordinator's, the remote fetch's, the debug fake's — hands `-cancel` one block** (`installCancelTransfer:token:`), installed only while its token is current; a cancel that came first is run by the caller at once.

**A fresh `NSFileCoordinator` per download** — cancelling poisons one for good, so reusing it would turn the first abort into a permanent refusal to download anything. `materializeURL:` builds one per call, and `AudioFileMaterializationCoordinator` a fresh `CloudFileMaterializer` per admitted run.

**TRAP: cancelling stops *us* waiting.** Whether the provider abandons the transfer is its own business — a replicated extension's `fetchContents` gets an `NSProgress` the system *may* cancel once nothing waits on it, but nothing promises that. It frees the lane and the thread at once; it does not promise to free the bandwidth.

`Vibe/Debug/VibeFakeCloud` drives it with a fake transfer provider, so the cloud paths can be exercised without a real provider.

**A second backend: the remote fetch.** A shell that keeps its own placeholders installs its root and a pair of blocks at launch, all or none, `setRemoteRoot:fetch:read:` (iOS: the Dropbox mirror, `iOS/Dropbox/AGENTS.md`). The root scopes `NSURLUtil`'s remote placeholder rule, so the dataless verdict and the backend that answers it cannot disagree, and an unreadable file outside the mirror is never sent to Dropbox. `materializeURL:` sends a remote placeholder there instead of to `NSFileCoordinator`; the block blocks the worker until the bytes have replaced the placeholder, and hands back a cancel block through `onCancel` that `-cancel` runs from any thread (at once, if the cancel came first). **Unlike the provider path, this cancel stops the transfer**, not just the wait. Everything above it — the claim, the lanes, the foreground hold, the loading bar — is unchanged, because it keys off the dataless verdict alone. **The second block, `remoteRead`, reads a placeholder's bytes by range** for the tag parse (`Audio/Metadata/AGENTS.md`), so opening a folder costs its tags, not its files. The mac installs nothing, and there an unreadable file is merely unreadable.

## Why the monitor and the materializer are not merged

They look like one thing and are opposites in the two ways that matter: the monitor **observes and must never trigger** a download and is main-thread only, while the materializer **causes** one, can abort it, and must never run on main. Merging them would put "never triggers" and "triggers" behind one name. The overlap that is real — *is this file here yet* — already lives in one place, `NSURLUtil.isDatalessFile:`.

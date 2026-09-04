# System

Bridges to OS services that are neither the audio engine nor the app's UI. Both platforms drive everything here, and nothing here knows which one it is talking to beyond a `TARGET_OS_OSX` guard around an API that genuinely differs.

Three residents, and the bar is the test all of them pass: **it talks to the system on the app's behalf, it holds no playback state of its own, and both targets need it.** Something only one platform can use belongs in that platform's directory; something with no OS service behind it is `Util/`.

## NowPlayingController

The `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` bridge: publishing what is playing, and receiving hardware transport commands back. It owns no playback state — its driver hands it track and timing updates and takes the commands back through the delegate, routing them to the same transport entry points the on-screen buttons use. `MainPlayerController+NowPlaying` is that driver on macOS, `PlaybackController+NowPlaying` on iOS.

`MPNowPlayingInfoCenter.playbackState` is the one macOS-only write (the property does not exist on iOS, which derives state from the audio session and the published rate) and it is guarded.

The republish position rule is header-only in `NowPlayingRules.h`, tested — beside the controller that is its only caller, and on this side of the platform boundary because both platforms' publishes run through it.

**TRAP: the published artwork must be privately rasterized on the main thread, and that result must be the only thing the `MPMediaItemArtwork` request handler hands back.** The handler is invoked on the media daemon's threads, and the source is the live `NSImage` the header, dock tile and playlist cells are drawing from — `NSImage` is not safe to draw concurrently, so drawing it inside the handler races the UI. `VibeArtworkForPublishing` always redraws even an already-small thumbnail, caps larger art at 512px, and gives the daemon a private `NSImage` and bitmap representation.

**TRAP: the debug-only `--no-audio-hw` flag suppresses all of it** — no publish, no command registration — because becoming the system's active media app pulls auto-switching AirPods over from another device even when no output device was ever opened. Verifying this class needs a launch *without* that flag; under it `dump_now_playing` always reports `hasInfo: 0`. See the `vibe-debug` skill.

**Nothing is published until the first track plays.** `updateWithTrack:…` withholds every publish before its first Playing one — a nil track, a parked or paused start alike — so an app launching into a restored session cannot claim the system slot; next/previous command availability is applied before that return regardless. After the first play a nil track clears the slot once.

## DownloadProgressMonitor

Best-effort download progress for a cloud file being materialized by its file provider, feeding the waveform's loading indicator on both platforms: shimmer while indeterminate, determinate fill when a fraction is known. Main thread only, like the delegate paths it feeds. **It observes and must never trigger a download** — the player's open is what actually fetches.

**`+monitorReplacing:forURL:currentURL:movement:handler:` is how a screen starts one.** A monitor outlives fast track changes, so a late sample would paint the wrong track's bar. The class method cancels the outgoing monitor, starts the new one, and drops any fraction whose URL is no longer what `currentURL` answers; the two-step init/start it wraps is private to the class. Both shells call it from their `+PlayerEvents`, while preserving it when a same-row replay still owns the same underlying open identifier.

Three sources, best wins. Everywhere: a poll of the dataless file's allocated size against its logical size, plus an iCloud `NSMetadataQuery` when the item is in iCloud's index. macOS also has the File Provider `NSProgress` publication, exact when the provider publishes and superseding the poll. iOS has no consumer-side progress API for third-party providers, so those files have only the poll — the header records why, so nobody re-researches it.

`DownloadProgressMonitor` owns only source precedence, movement and whole-percent coalescing. The private classes in `DownloadProgressSourceAdapters` each own one system lifecycle — timer, metadata query or File Provider subscription/KVO — including its complete cancellation path. A new observation mechanism belongs behind the same fraction callback instead of adding another lifecycle to the monitor.

`DownloadProgressSourceAdaptersInternal.h` narrows the host-less boundary to iCloud query construction/ubiquity lookup and File Provider subscriber registration. The tests still drive the production notification, filtering, KVO, replacement, unpublish and cancellation paths; only the OS finding a cross-process publication remains a live-app check.

An `NSProgress` unpublish is not completion: it also covers an abandoned operation or a disappearing provider. It detaches that exact source and lets the poll verify the file; only a reported 100% or materialized filesystem state publishes completion.

The UI fraction remains whole-percent coalesced, but transfer liveness is not. Only a finite, strictly positive raw increase is movement; initial zero, repeated, backward, negative and NaN samples never extend the player's deadline. The fake source passes zero through the same rule rather than silently hiding the provider's initial-value shape.

Both of those decisions are `DownloadProgressRules.h`, header-only and tested: `VibeDownloadProgressIsMovement` is the liveness half, and `VibeDownloadPollShouldPublish` is the poll's — the two-part dataless-and-blocks test the trap below turns on.

**TRAP: a clear `SF_DATALESS` is not proof the file is here.** It is also what a provider that never sets the flag looks like, and treating that as materialized reported a motionless 100% for a download that had not begun. The flag being down and the allocated blocks being there must **both** hold; with no positive fraction the monitor reports nothing at all rather than a zero.

**TRAP: `NSURLIsUbiquitousItemKey` is not an iCloud test.** Every File Provider item answers YES to it — a Dropbox file included — so it only gets as far as "some cloud". The `NSMetadataQuery` is what settles it, and it stops on an item iCloud does not index rather than idling for the length of the download.

`Vibe/Debug/VibeFakeCloud` stands in for the provider's reporting too, and its seam **replaces** the sources above rather than joining them: under a fake transfer the file on disk is genuinely local, so the poll would answer a final 100% on its first tick. `DownloadProgressMonitor+Debug.h` carries the whole rule.

## CloudFileMaterializer

Pulls a file provider's placeholder down to disk as an explicit, **abortable** step, for background work that needs a cloud file's bytes and must be able to stop wanting them. Background only — it blocks for a transfer, and coordinating on main is how an app deadlocks against its own presenters.

It exists because an ordinary read cannot be interrupted. Opening a dataless file — TagLib's read, `AVAudioFile`'s open — blocks in the kernel until the provider finishes, whatever the app decides meanwhile. `NSFileCoordinator`'s `-cancel` is the one documented way out ("any current invocation will stop waiting and return immediately", from any thread), which is why the download is coordinated here rather than left implicit inside whatever opens the file next.

Its sole production caller is `AudioFileMaterializationCoordinator` in `Vibe/Audio/`. That coordinator wraps each admitted path-wide run in a fresh materializer, while playback, prefetch and metadata attach role-bearing waiters to the one standardized-path claim. Consumers cancel their own request tokens; only the last waiter leaving, or a central metadata yield, reaches this primitive's cancel path. Neither the coordinator's handle-open stage nor `AudioTrackMetadataLoader` mints a materializer directly.

**Cancellation has exactly one spelling here**, `VibeMaterializationCancelledError` (`NSCocoaErrorDomain` / `NSUserCancelledError`, which is also what `NSFileCoordinator` returns for its own `-cancel`). Above this primitive, the central coordinator's result enum — Ready, Yielded, AdmissionExhausted or Failed — is the policy surface; callers do not infer retry behavior from this underlying error.

**A fresh `NSFileCoordinator` per download** — cancelling poisons one for good, so reusing it would turn the first abort into a permanent refusal to download anything. `AudioFileMaterializationCoordinator` enforces that lifetime by creating a fresh `CloudFileMaterializer` operation for each admitted run.

**TRAP: cancelling stops *us* waiting.** Whether the provider abandons the transfer is its own business — a replicated extension's `fetchContents` gets an `NSProgress` the system *may* cancel once nothing waits on it, but nothing promises that. It frees the lane and the thread at once; it does not promise to free the bandwidth.

`Vibe/Debug/VibeFakeCloud` drives it with a fake transfer provider, so the cloud paths can be exercised without a real provider.

## Why the monitor and the materializer are not merged

They look like one thing and are opposites in the two ways that matter: the monitor **observes and must never trigger** a download and is main-thread only, while the materializer **causes** one, can abort it, and must never run on main. Merging them would put "never triggers" and "triggers" behind one name. The overlap that is real — *is this file here yet* — already lives in one place, `NSURLUtil.isDatalessFile:`.

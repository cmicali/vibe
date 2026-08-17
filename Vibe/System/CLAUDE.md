# System

Bridges to OS services that are neither the audio engine nor the app's UI. Both platforms drive everything here, and nothing here knows which one it is talking to beyond a `TARGET_OS_OSX` guard around an API that genuinely differs.

Three residents, and the bar is the same test all of them passed: **it talks to the system on the app's behalf, it holds no playback state of its own, and both targets need it.** Something only one platform can use belongs in that platform's directory; something with no OS service behind it is `Util/`.

## NowPlayingController

The `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` bridge: publishing what is playing, and receiving the hardware transport commands back. It owns no playback state — its driver hands it track and timing updates and takes the commands back through the delegate, routing them to the same transport entry points the on-screen buttons use. `MainPlayerController+NowPlaying` is that driver on macOS, `PlayerViewController` on iOS.

`playbackState` is the one macOS-only write (the property does not exist on iOS, which derives its state from the audio session and the published rate), and it is guarded.

TRAP: the debug-only `--no-audio-hw` flag suppresses all of it — no publish, no command registration — because becoming the system's active media app pulls auto-switching AirPods over from another device even when no output device was ever opened. Verifying this class therefore needs a launch *without* that flag; `dump_now_playing` always reports `hasInfo: 0` under it. See the `vibe-debug` skill.

The republish position rule is header-only in `NowPlayingRules.h`, tested — beside the controller that is its only caller, and on this side of the platform boundary because both platforms' publishes run through it.

## DownloadProgressMonitor

Best-effort download progress for a cloud file being materialized by its file provider, feeding the waveform's loading indicator on both platforms: shimmer while indeterminate, determinate fill when a fraction is known.

**`monitorReplacing:forURL:currentURL:handler:` is how a screen starts one**, because the guard is the part both were restating: a monitor outlives fast track changes, so a late sample would paint the wrong track's loading bar. The class method cancels the outgoing monitor, starts the new one, and drops any fraction whose URL is no longer what `currentURL` answers. `startWithHandler:` remains for a caller that owns that check itself.

Two sources, best wins. Everywhere: the portable heuristic, polling the dataless file's allocated size against its logical size. macOS only: the File Provider `NSProgress` publication, exact when the provider publishes, superseding the poll. iOS has no consumer-side progress API for third-party providers, so the poll is the whole story there.

Its header carries the measurements — both iCloud Drive and Dropbox stage out of line, so the poll is a floor rather than the feature — and they are the reason the shape is "two sources, best wins" rather than one. Read it before changing either source.

**On iOS there is no fraction to be had, and the header records why so nobody re-researches it**: `+addSubscriberForFileURL:` is `API_UNAVAILABLE(ios)`, `NSFileProviderItem` publishes no percentage (and its `isDownloading` is documented as ignored for the replicated extensions modern providers are), and `globalProgressForKind:` needs a domain only the provider's own app can hold. A replicated extension fetches into its own temp file and has the system swap it in, which is exactly what the poll cannot see. So iOS shows the indeterminate shimmer, and the poll is kept honest about it: **a clear `SF_DATALESS` is not proof the file is here** — it is also what a provider that never sets the flag looks like, and treating that as materialized reported a motionless 100% for a download that had not begun. The flag being down and the allocated blocks being there must agree, and with no positive fraction the monitor reports nothing at all rather than a zero.

## CloudFileMaterializer

Pulls a file provider's placeholder down to disk as an explicit, **abortable** step, for background work that needs a cloud file's bytes and must be able to stop wanting them.

It exists because an ordinary read cannot be interrupted. Opening a dataless file — TagLib's read, `AVAudioFile`'s open — blocks in the kernel until the provider finishes, whatever the app decides meanwhile: a background metadata parse that has started pulling down a 60MB track owns its lane for the whole transfer, and the only lever left is refusing to start new ones. `NSFileCoordinator`'s `-cancel` is the one documented way out ("any current invocation will stop waiting and return immediately", from any thread), which is why the download is coordinated here rather than left implicit inside whatever opens the file next.

Three callers, each with a slot of its own so they cannot cancel each other: the metadata scan's cloud lane (`AudioTrackMetadataLoader`, cancelled by the foreground-download hold), and the player's play and prefetch opens (`AudioPlayerInternal.h`, each cancelled when superseded and both on `stop`). **A fresh coordinator per download** — cancelling poisons one for good, so reusing it would turn the first abort into a permanent refusal to download anything. And the caller's gate must **suspend before it cancels**, or the cancelled parse's re-queue restarts the same download immediately: a cancel loop rather than a hold.

TRAP: cancelling stops *us* waiting. Whether the provider abandons the transfer is its own business — a replicated extension's `fetchContents` gets an `NSProgress` the system *may* cancel once nothing waits on it, but nothing promises that. It frees the lane and the thread at once; it does not promise to free the bandwidth. Measuring that needs a real provider, and it is still unmeasured.

### Why it is not merged with DownloadProgressMonitor

They look like one thing — both are per-URL, short-lived, and about a cloud file arriving — and they are opposites in the two ways that matter:

| | DownloadProgressMonitor | CloudFileMaterializer |
| --- | --- | --- |
| Relationship to the download | **observes, and must never trigger one** (its header says so, and the player's open is what actually fetches) | **causes it**, and can abort it |
| Thread | main only, like the delegate paths it feeds | background only; it blocks for a transfer, and coordinating on main is how an app deadlocks against its own presenters |

Merging them would put "never triggers" and "triggers" behind one name, and main-only beside must-never-run-on-main. The overlap that is real — *is this file here yet* — already lives in one place, `NSURLUtil.isDatalessFile:`, and that is the thing to share if a third consumer appears.

The one argument for merging is worth recording, because it may come back: the materializer knows exactly when a download starts and ends, so for a download **it** started it is the natural place to report progress from — better than a poller inferring one from `stat`. If a usable per-file progress source ever appears (see the monitor's header for why there isn't one on iOS today), revisit it then, from that direction.

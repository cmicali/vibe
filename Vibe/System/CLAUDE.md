# System

Bridges to OS services that are neither the audio engine nor the app's UI. Both platforms drive everything here, and nothing here knows which one it is talking to beyond a `TARGET_OS_OSX` guard around an API that genuinely differs.

Two residents, and the bar for a third is the same test both passed: **it talks to the system on the app's behalf, it holds no playback state of its own, and both targets need it.** Something only one platform can use belongs in that platform's directory; something with no OS service behind it is `Util/`.

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

On iOS there is no fraction to be had, and the header records why so nobody re-researches it**: `+addSubscriberForFileURL:` is `API_UNAVAILABLE(ios)`, `NSFileProviderItem` publishes no percentage (and its `isDownloading` is documented as ignored for the replicated extensions modern providers are), and `globalProgressForKind:` needs a domain only the provider's own app can hold. A replicated extension fetches into its own temp file and has the system swap it in, which is exactly what the poll cannot see. So iOS shows the indeterminate shimmer, and the poll is kept honest about it: **a clear `SF_DATALESS` is not proof the file is here** — it is also what a provider that never sets the flag looks like, and treating that as materialized reported a motionless 100% for a download that had not begun. The flag being down and the allocated blocks being there must agree, and with no positive fraction the monitor reports nothing at all rather than a zero.

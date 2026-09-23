# System

Bridges to OS services that are neither the audio engine nor the app's UI. Both platforms drive everything here, and nothing here knows which one it is talking to beyond a `TARGET_OS_OSX` guard around an API that genuinely differs.

Four residents, and the bar is the test all of them pass: **it talks to the system on the app's behalf, it holds no playback state of its own, and both targets need it.** Something only one platform can use belongs in that platform's directory; something with no OS service behind it is `Util/`.

## NowPlayingController

The `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` bridge: publishing what is playing, and receiving hardware transport commands back. It owns no playback state — its driver hands it track and timing updates and takes the commands back through the delegate, routing them to the same transport entry points the on-screen buttons use. `MainPlayerController+NowPlaying` is that driver on macOS, `PlaybackController+NowPlaying` on iOS.

`MPNowPlayingInfoCenter.playbackState` is the one macOS-only write (the property does not exist on iOS, which derives state from the audio session and the published rate) and it is guarded.

`initWithClock:publish:commandAvailability:` runs the same publication path without registering remote commands. Host-less tests inject the clock and OS writes to cover first-play gating, clearing, dirty detection, command changes and artwork promotion; actual system registration remains a live-app check.

The republish position rule is header-only in `NowPlayingRules.h`, tested — beside the controller that is its only caller, and on this side of the platform boundary because both platforms' publishes run through it.

**TRAP: the published artwork must be privately rasterized on the main thread, and that result must be the only thing the `MPMediaItemArtwork` request handler hands back.** The handler is invoked on the media daemon's threads, and the source is the live `NSImage` the header, dock tile and playlist cells are drawing from — `NSImage` is not safe to draw concurrently, so drawing it inside the handler races the UI. `VibeArtworkForPublishing` always redraws even an already-small thumbnail, caps larger art at 512px, and gives the daemon a private `NSImage` and bitmap representation.

**TRAP: the debug-only `--no-audio-hw` and `--no-now-playing` flags suppress all of it** — no publish, no command registration — because publishing can pull AirPods from another device even when rendering to a virtual output. `--no-now-playing` leaves hardware rendering enabled for loopback tests (`VIBE_NOW_PLAYING=0` in the launcher). Verifying this class needs a launch without either flag; under either one `dump_now_playing` reports `hasInfo: 0`. See the `vibe-debug` skill.

**Nothing is published until the first track plays.** `updateWithTrack:…` withholds every publish before its first Playing one — a nil track, a parked or paused start alike — so an app launching into a restored session cannot claim the system slot; next/previous command availability is applied before that return regardless. After the first play a nil track clears the slot once.

## The widget: WidgetPublisher, VibeWidgetState, the reloader and the intents

The iOS Home Screen widget and the macOS desktop widget are one WidgetKit extension built per platform (`project.yml`'s `VibeWidgetBase` template; its views live in `VibeWidget/`, outside `Vibe/`, so no app target recurses them). The app side is here because it is `NowPlayingController`'s shape pointed at a second process: each shell's Now Playing publish hands `WidgetPublisher` the same instant it hands the system card (`PlaybackController+NowPlaying` on iOS, `MainPlayerController+NowPlaying` on the mac), plus the complete waveform envelope and, on the mac, a call from `applySettingsLiveEffects:` where iOS subscribes to its settings notification.

- **The extension draws only what `WidgetPublisher` wrote.** It links no app class; `VibeWidgetState` (Foundation-only, compiled into both sides) is the whole contract: a plist naming the track, and three images named by that track's key, written images-first so a plist never names a file that has not landed.
- **A track change is one reload, not three.** Its plist, cover and strip land at different moments, and while the app is frontmost WidgetKit defers a reload asked for during another's ~1.5 s render until 5 s after that one began, so the publisher holds the track change's reload until the cover and strip are written, at most `kWidgetTrackChangeHold`. The trap is `WidgetPublisher.m`'s.
- **Writes are gated on a widget being placed**, and turned on by the extension's Darwin read signal, off only by WidgetKit's own answer (`refreshPlaced`, on iOS scene activation and mac app activation).
- **A widget button runs in the app because the intents are `AudioPlaybackIntent`s** (`VibeWidgetIntents.swift`, compiled into the extension for the types and into each app for the bodies, behind `VIBE_APP`). Each shell waits for its launch open to settle before acting: iOS `PlaybackController.performWhenLaunchOpenSettled:`, mac `AppDelegate.performWhenLaunchOpenSettled:`.
- **The publisher's only platform branches** are where the bake reads its inputs (iOS's loose waveform settings versus the mac's `currentTheme` plus Normalize and Gain) and who triggers a settings re-bake. Images cross to its queue as `CGImage`s taken on main, and encode through `PlatformImage.h`'s `VibeEncodedImageData`.
- **`#import "Vibe-Swift.h"` names one header in both apps**: both products are `Vibe`, so the generated interface shares its name. The Swift in each app is only the reloader and the intent bodies; each target's `Vibe-Bridging-Header.h` says so.

**TRAP: the app group is spelled differently per platform, and each spelling is the only one that works there** (`VibeWidgetState.m`). From macOS 15 a container is granted only to an App Store app, a profile-authorized group, or a team-prefixed one — and an extension that fails is denied silently, which draws an empty widget. The mac's is `4UEV752JH4.com.commonwealthrecordings.Vibe`, iOS's `group.com.commonwealthrecordings.Vibe`. **An ad-hoc signature carries no team**, so the default `make build` gets no container either: exercise the mac widget with `make build VIBE_SIGN_MAC=1` (the Makefile's signing TRAP). Both release scripts check the exported bundles still hold the group.

The mac extension deploys to 26.0 (the intents' `supportedModes`), so the widget is absent below 26 while the app still runs on 13.

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

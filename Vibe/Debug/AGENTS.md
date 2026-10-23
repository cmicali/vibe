# The debug command channel

How a running app is driven and read from outside, on both platforms. **The verbs are deliberately not listed here.** The unknown-command reply derives from the command tables. The `vibe-debug` skill documents their usage. This file is the structure: what the pieces are, which are shared, and where a new verb goes. Read the `vibe-debug` skill first to use the channel, and this file to change it.

## Layout

Each shared subdirectory matches a section below.

- **`Channel/`** is the transport.
- **`Verbs/`** holds the verbs both platforms answer, one file per topic, and the protocol they are written against.
- **`Oracles/`** holds the oracles.
- **`Simulators/`** holds the simulators.
- **`Seams/`** holds the `+Debug` categories over shared classes. The next section says why they live here. **A seam imports nothing from `Channel/` or `Verbs/`.** It belongs to the class it opens, and moves with that class to vibe-libs, which has no channel. The file loader's seams and the fake cloud already have (vibe-libs' `files/FileLoading/AGENTS.md`). So have the FX fault seam, the meter's two seams, the file handle's, and the metadata cache's and loader's (vibe-libs' `audio/FX/AGENTS.md`, `audio/Meter/AGENTS.md`, `audio/Decode/AGENTS.md`, and `media/Metadata/AGENTS.md`). A parser a seam and the channel share lives in vibe-libs' `core/Common`, as `IntegerTokenRules.h` does.

`Mac/` and `iOS/` hold each platform's table and verbs. Each has its own `Seams/` for the `+Debug` categories over that shell's classes.

## It is in both targets' sources and ships in neither

`project.yml` lists `Vibe/Debug` as an ordinary shared subsystem, so the layout rule needs no exception for it. **Every file is wrapped in `#if DEBUG`**, which a Release build compiles to an empty object.

This is why a shipping header may not carry `#if DEBUG` (root `AGENTS.md`, Vocabulary). The surface a debug build adds to a shipping class is declared here, in a `+Debug` category header (`AudioTrackMetadataLoader+Debug.h` and the others). A class that moved to vibe-libs took its seam along, beside it (vibe-libs' `audio/Player`'s `AudioPlayer+Debug.h`). When the methods need only what the class exposes in its header or its `*Internal.h`, they live here too, in `<Class>+Debug.m` (`AudioTrackMetadataLoader+Debug.m`). When they need state private to the class's own file, they stay in that file under `#if DEBUG`, and the header says so (`NowPlayingController.m`, and vibe-libs' `EqualizerIndicatorView.m`). Process-wide debug state, such as a fake's hooks, is a file static in the seam's `.m`. The shipping class reaches it through a category method or a function the seam header declares (vibe-libs' `AudioWaveformCache+Debug.mm`, in `waveform/WaveformLoading`). A small hook inside a shipping method stays there under `#if DEBUG`, such as a counter or a hold in the render or decode loop. Three shapes cover what a category cannot add:

- **Debug-only state** becomes a debug-only object the shipping class holds: vibe-libs' `VibeManualRenderPump`, which the player holds.
- **A debug-only field a seam reads** is declared unconditionally in the class's private header (its `*Internal.h`, or its one header), marked "Debug builds only". Release never writes it. `AudioPlayerInternal.h`'s buffering counts and `AudioVoiceBusInternal.h`'s debug fields are examples.
- **A debug-only hook** ships as a plain block pointer with no conditional around it: `MainPlayerControllerInternal.h`'s `undoRedoSettledHandler`, and `AudioFileConverterInternal.h`'s `nextSourceTrashResultingURLFilter`.

**A test target compiles every seam its sources reach.** A seam with its own `<Class>+Debug.m` must be in the test target's sources when the target compiles the class and a file in it imports the seam's header, directly or through another seam. A selector resolves at run time, so the compiler cannot catch an omitted category implementation. `make check-layout` fails on the gap.

**`AudioFileHandle+Debug.h` is the network-mount read-ahead's seam**, so a test plays a local file as if it were on a share. It moved with the handle to vibe-libs' `audio/Decode`, whose `AGENTS.md` states its contract. **TRAP: the rule and the hook are set on a test's thread and read on open and read-ahead threads, so both are read under a lock.** An unlocked read of a block global is a retain racing a release. The seam's statics live in vibe-libs' `files/FileLoading/Transfer/NetworkReadAhead.m` under `#if DEBUG`. The common verb `set_slow_volume` drives the seam in a running app: it forces the rule for every file and installs one hook that throttles, stalls or fails each read. Its state lives in `Verbs/DebugStallVerbs.m` under one `NSCondition`, on which a held read waits. Each set releases every held read.

## The transport, and the two ends of it

A command is a file. The client writes one, the app drains it, and the app writes a reply file back.

| Piece | Owns |
| --- | --- |
| `DebugWireFormat.{h,m}` | The wire: the notification name, the command, response and screenshot paths, and the JSON reply serialization. Both apps' tables, the shared verbs and the mac CLI client must agree on it. |
| `DebugChannel.{h,m}` | The platform-neutral drain: payload validation, response writing, the stale-file sweep and the wake-up listeners. It holds no verbs; the platform table supplies an executor block. |
| `DebugCommandDispatch.{h,m}` | The table's shape and the lookup over it, so one lookup and one unknown-command reply serve both platforms. It never invokes a handler, since each platform's dispatcher supplies its own controller. |
| `Mac/DebugClient.m` | The macOS CLI half. `main.m` routes `Vibe --debug-cmd …` here **before `NSApplicationMain`**, so the client is the same binary and never launches a second app. |

iOS has no client. `debug-ios.sh` writes the command file straight into the simulator container's tmp, a plain host directory.

## A verb is written once unless it cannot be

`Verbs/` holds every verb both platforms can answer. They are written against **`VibeDebugPlayerSurface`** (`DebugPlayerSurface.h`), the smallest protocol that serves them. `MainPlayerController` adopts it on macOS, and `RootViewController` on iOS, since that is the one object that sees the whole iOS app.

The verbs are split by topic. `DebugCommonVerbs.m` holds the state and transport verbs and the shared table. The table adds each topic's verbs after its own. `DebugStallVerbs.m` holds the deliberate stalls: the `block_*` verbs, `hang_open` and `set_slow_volume`. `DebugAudioVerbs.m` holds the meter, decoder, resampler, render-counter, cache, timing, waveform and tempo-scan verbs. The scan's core is `DebugBPMScan.mm`, which the mac's CLI client also runs in its own process. `DebugLoadingVerbs.m` holds the cloud, row-loading, loading-indicator, loading-configuration and link verbs. It also drives the fake cloud and the fake HTTP server. Each platform's dispatcher looks a verb up in the shared table first, so a verb is registered once.

What is left per platform is what genuinely differs:

- **`Mac/`**: the entry points and the dispatcher (`DebugMacEntry.{h,m}`), and the command table (`DebugMacVerbs.m`). The table adds four topic tables after its own verbs: `DebugThemeVerbs.m`, `DebugWindowVerbs.m`, `DebugOutputVerbs.m` and `DebugConvertVerbs.m` (with undo and redo). The AppKit-only helpers are `DebugInput.m` (direct playlist selection, named gesture probes and raw input), `DebugSyntheticDrags.m` (the synthetic drop and reorder delegates), `DebugScreenshot.m`, `DebugSettingsUI.m` (the structural Settings walker's verbs; its walk from a row to its controls is vibe-libs' seam `SettingsFormViews+Debug.h`, in `ui/SettingsWindow`), `DebugStateDump.m` and `DebugMacConsistency.m` (the mac half of `check_consistency`). `Mac/Seams/` holds the `+Debug` categories over the mac shell's classes, plus `MainPlayerController+DebugPlayerSurface`.
- **`iOS/`**: the entry point and the dispatcher (`DebugiOSEntry.{h,m}`), the command table (`DebugiOSVerbs.m`), the Dropbox verbs it adds after its own (`DebugDropboxVerbs.m`, beside `VibeFakeDropbox`), the verbs that stand in for touches the channel cannot synthesize (`expand_player`, `minimize_player`, `select_tab`, and the favorites, search, route and waveform verbs), and the `+Debug` categories over the iOS shell in `iOS/Seams/`. All of them live here, not beside the classes they extend.

**Gestures are not the channel's job on iOS.** No public API synthesizes a `UITouch` in-process. Taps and drags go through `drive-ios.sh` and the resident `VibeiOSDriver` XCUITest in `Tests/iOSDriver/`, which is not part of `VibeTests`.

## Desktop input boundary

The stress runner permits only reviewed controller and delegate commands, including direct table selection and shell removal. Synthetic file drops and row reorders (`Mac/DebugSyntheticDrags.m`) call shipping delegates without native drag sessions. Raw AppKit events (`Mac/DebugInput.m`) can start native window and file drags, and mouse injection activates the app. So they are reserved for explicit gesture tests on an isolated test desktop. The named pitch-fader probes resolve and hit-test fresh geometry before queuing input, and the runner asserts the result. Replay and shrink enforce the same command gate. The workflow is in `vibe-debug` and `vibe-stress`.

## The oracles

These exist for the stress driver, which cannot tell a healthy soak from a leaking one by screenshotting it.

- **`DebugConsistency.{h,m}`**: the checks that hold on both platforms, behind the same surface protocol. Each platform adds its own through `debugCheckPlatform:`. iOS flags row lifts older than 30 seconds. That threshold can also catch a slow multi-folder open. A violation needs investigation against the operation in flight. **TRAP: a check that compares a published or rendered value against the state that produced it can lag a run-loop turn.** Count only a violation that survives a re-check after a short settle, as the stress driver does.
- **The layout probe** (`dump_layout_anchors`, `sample_layout_anchors`) and **the frame probe** (`sample_frame_rate`, `--frame-rate-probe`) are the iOS shell's oracles for what a screenshot cannot judge: whether the live layout under the card held still, and whether an animation got its frames.
- **`DebugHealth.{h,m}`**: `dump_health`'s process and UI resource counts, for diffing across a run, and `quiesce`, on both platforms. Each platform gives its UI block, its close and any pending work of its own through the surface. iOS has no `libproc`, so it counts file descriptors by probing the table. Warm the lazy FX units before taking a leak baseline. Quiesce pending work before comparing memory. Allocator reservations and live allocations are separate readings.
- **`AudioLoadTiming`**: per-phase timings for one waveform decode pass, recorded by the loader and read afterwards, since that pass has no reply path. It is the loader's seam, `AudioWaveformLoader+Debug.h`, in vibe-libs' `waveform/WaveformLoading`. `dump_timing` and `file_cache` read it.
- **The work tally** is a named counting window over the signpost sites. It answers "how much of this work ran at all". It is vibe-libs' `core/Common/VibeWorkTally`, beside the signposts in `VibeMacros.h`, so call sites need no debug header. It compiles only under `VIBE_SIGNPOSTS`, which `project.yml` defines in Debug.

## The simulators of things the app cannot otherwise reach

- **`VibeManualRenderPump`** stands in for the output unit's IO thread, which `--no-audio-hw` never starts. It is vibe-libs' `audio/Player`'s, beside the player it fakes, and that piece's doc is its authority. It calls the production render at real-time pace, so voices are consumed and the timeline advances as against hardware. `VibeAudioTests` drives the same pump with explicit frame pulls and a virtual clock. It lets the whole player run with no audio device, under a sanitizer or on a machine with none.
- **`iOS/VibeFakeDropbox`** stands in for the Dropbox account. A directory on disk answers as the account over the client's own HTTP boundary: an `NSURLProtocol` on sessions the client rebuilds through `useSessionConfiguration:` (`HTTPTransferClientInternal.h`, imported by `DropboxClientInternal.h`). The account is linked as a completed sign-in would be, and the mirror, the browser, search and every open run unchanged. Downloads arrive in 64 KB pieces over a chosen time or at a chosen rate, a resend continues from its Range, and each file has a rev every answer names. Scripted faults drive each of the client's streaming roads: a stall, a dropped connection, a changed rev, a throttle, an expired token, a failed or slow tail read, and a server's first-byte latency. **TRAP: never rebuild the sessions under transfers in flight** (the `TRAP:` in `VibeFakeDropbox.m`).
- **`VibeFakeHTTP`** stands in for the web server behind an Open URL link, on both platforms. A directory on disk answers as `https://fake.vibe.test/` and `http://fake.local/`. It sits under `LinkStore.shared.client` through `useSessionConfiguration:`, and `set_fake_http off` puts the real sessions back. While installed it answers every request on those sessions, so a refused link shows zero requests. A file answers as a server with ranges does: 206, 416 and 200, with its length, ETag, Last-Modified and type. An open range is paced in 64 KB pieces. Faults script what real servers do: a stall, a lost connection, a new version, a throttle, a slow first byte, no ranges, no length, a radio stream, a status, a web page and gzip. `open_url` resolves a link through each shell's own Open URL road (`debugOpenLink:`). **Its serving engine is the tests' `HTTPStub` too.** `VibeFakeHTTPProtocol` is the one `NSURLProtocol`, `VibeFakeHTTPRangeStatus` the one Range rule, and `VibeFakeHTTPAnswer` the one body delivery. The three live in `VibeFakeHTTPProtocol.{h,m}`. The directory's answers are the protocol's `Directory` category in `VibeFakeHTTP.m`, in address, lookup, fault, range and pace steps. `HTTPStub`'s `HTTPStubProtocol` subclasses the protocol and only scripts each answer. **TRAP: a lost connection waits until the task holds the bytes sent before it.** Sent at once, the failure overtakes them, and the session resends the whole request itself instead of the client's Range resend.
- **`VibeFakeCloud`** stands in for a file provider. Chosen files answer as placeholders, each takes a fixed time to download, and a cancel leaves the file a placeholder. It lives in vibe-libs' `files/FileLoading`, beside the three points it injects at: `PlaceholderFiles`' dataless probe, `CloudFileMaterializer`'s transfer and `DownloadProgressMonitor`'s reporting. That piece's doc is its authority. `Verbs/DebugLoadingVerbs.m` installs it here, and the cloud-loading scenario suite drives it through the channel. **TRAP: its progress seam replaces the monitor's real sources rather than joining them** (`DownloadProgressMonitor+Debug.h`). Under a fake transfer the file on disk is genuinely local, so the allocated-size poll would answer 100% on its first tick.

## Adding a verb

Decide which table it belongs in first. A verb both platforms can answer goes in its topic's file under `Verbs/`, or in `DebugCommonVerbs.m` when no topic fits. If it needs something new from the app, it adds the smallest possible method to `VibeDebugPlayerSurface`. A verb only one platform can answer stays in that platform's table or one of its topic tables, and never reaches the protocol. A new topic file joins its table's concatenation and declares its function beside the table's. The reply is JSON through `DebugWireFormat`. The skill's documentation follows the usage string, not a list kept here.

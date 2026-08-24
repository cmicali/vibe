# The debug command channel

How a running app is driven and read from outside it, on both platforms. **What the verbs *are* is deliberately not written here** — the list lives in the `vibe-debug` skill and in the channel's own unknown-command reply, so it cannot drift from the tables. This file is the structure: what the pieces are, which of them is shared, and where a new verb goes.

Read the `vibe-debug` skill first if the goal is to *use* the channel. Read this if the goal is to change it.

## It is in both targets' sources and ships in neither

`project.yml` lists `Vibe/Debug` as an ordinary shared subsystem — recursive, with the usual `Mac/**` or `iOS/**` exclude — so the layout rule needs no exception for it. What keeps it out of the product is that **every file is wrapped in `#if DEBUG`**, which a Release build compiles to an empty object.

That is also why root `CLAUDE.md`'s vocabulary rule 4 exists: a *shipping* header may not carry `#if DEBUG`, because the surface a debug build adds to a shipping class belongs here instead, as a declaration-only category (`AudioPlayer+Debug.h`, `AudioWaveformCache+Debug.h`, and the rest of the `+Debug` headers at this level). Two shapes cover what a category cannot add:

- **debug-only state** becomes a debug-only *object* the shipping class holds — `VibeManualRenderPump`;
- **a debug-only hook** ships as a plain block pointer with no conditional around it (`MainPlayerControllerInternal.h`'s `conversionUndoRedoSettledHandler`, and the converter's source-Trash result filter).

## The transport, and the two ends of it

A command is a file. The client writes one, the app drains it, the app writes a reply file back.

| Piece | Owns |
| --- | --- |
| `DebugWireFormat.{h,m}` | The wire itself: the notification name, the command/response/screenshot paths, and the JSON reply serialization. Neither app's, because both apps' tables, the shared verbs and the mac CLI client all have to agree on it. |
| `DebugChannel.{h,m}` | The platform-neutral drain: payload validation, response writing, the stale-file sweep, the wake-up listeners. It holds no verbs — the platform table supplies an executor block. |
| `DebugCommandDispatch.{h,m}` | The table's *shape* and the lookup over it, so one verb lookup and one unknown-command reply serve both platforms. It deliberately never invokes a handler: each table is typed to its own controller, and the call belongs where that type is known. |
| `Mac/DebugClient.m` | The macOS CLI half. `main.m` routes `Vibe --debug-cmd …` here **before `NSApplicationMain`**, so the client is the same binary and never launches a second app. |

iOS has no client: `debug-ios.sh` writes the command file straight into the simulator container's tmp, which is a plain host directory. The transport above it is the mac's verbatim.

## A verb is written once unless it cannot be

`DebugCommonVerbs.m` is every verb both platforms can answer, written against **`VibeDebugPlayerSurface`** — the smallest protocol that serves them, adopted by `MainPlayerController` on macOS and by `RootViewController` on iOS (`RootViewController` because it is the one object that can see the whole iOS app: the model's handles, the card's chrome, and the shell's own tab/strip/card state).

What is left per platform is what genuinely differs:

- **`Mac/`** — the command table plus the AppKit-only verbs: `DebugInput.m` (synthesized clicks, drags and keys), `DebugScreenshot.m`, `DebugSettingsUI.m` (the structural Settings walker — documented in `Mac/Settings/CLAUDE.md`, because it is useless anywhere else), `DebugStateDump.m`, `DebugHealth.m`, `DebugBPMScan.mm`. `Mac/Introspection/` holds the declaration-only `+Debug` categories over the mac shell's own classes.
- **`iOS/`** — the command table plus the three verbs the channel cannot synthesize a touch for (`expand_player`, `minimize_player`, `select_tab`), and the `+Debug` categories over the iOS shell. **All of them live here, not beside the classes they extend**, which is what rule 4 enforces.

**Gestures are not the channel's job on iOS.** No public API synthesizes a `UITouch` in-process, so taps and drags go through `drive-ios.sh` and the resident `VibeiOSDriver` XCUITest in `Tests/iOSDriver/` — which is not part of `VibeTests` (`Tests/CLAUDE.md`).

## The oracles

These exist for the stress driver, which cannot tell a healthy hour-long soak from a leaking one by screenshotting it.

- **`DebugConsistency.{h,m}`** — the checks that hold on both platforms, behind the same surface protocol; each platform adds its own through `debugCheckPlatform:`. A violation is a statement about state that should never be legal. **TRAP: a few checks compare a published or rendered value against the state that should have produced it, and those can lag a run-loop turn** — believe only what survives a re-check after a short settle, which is what the stress driver does.
- **`Mac/DebugHealth.{h,m}`** — `dump_health`'s process and UI resource counts, for diffing across a run rather than reading at a point.
- **`AudioLoadTiming.{h,m}`** — per-phase timings for one waveform decode pass, recorded by the loader and read after the fact, since that pass has no reply path of its own. Plain C accumulators so the ObjC++ loader and the plain-ObjC channel share the header.
- **`VibeWorkTally.{h,m}`** — a named counting window over the prefix header's signpost sites, answering "how much of this work ran at all" where Instruments answers "which work landed in the dropped frame". Its three functions are declared in `Vibe-Prefix.pch`, not here, so call sites reach them without importing a debug header.

## The two simulators of things the app cannot otherwise reach

- **`VibeManualRenderPump`** stands in for the HAL IO thread that `--no-audio-hw`'s manual rendering never starts, pulling frames through the engine at real-time pace and discarding them, so segments are consumed and `lastRenderTime` advances as they would against hardware. It is what lets the whole player run with no audio device, under a sanitizer or on a machine with none.
- **`VibeFakeCloud`** stands in for a file provider: chosen files answer as placeholders, each takes a fixed time to "download", and a cancel leaves the file a placeholder. It injects at exactly three chokepoints — `NSURLUtil`'s dataless probe, `CloudFileMaterializer`'s transfer, and `DownloadProgressMonitor`'s reporting — so everything above them runs unchanged. **Its progress seam *replaces* the monitor's real sources rather than joining them** (`System/CLAUDE.md`): under a fake transfer the file on disk is genuinely local, so the allocated-size poll would answer 100% on its first tick.

## Adding a verb

Ask which table it belongs in before writing it. A verb both platforms can answer goes in `DebugCommonVerbs.m` and, if it needs something new from the app, adds the *smallest* possible method to `VibeDebugPlayerSurface`; anything only one platform can answer stays in that platform's table and never reaches the protocol. Then check the reply is JSON through `DebugWireFormat`, and let the skill's documentation catch up from the usage string rather than from a list kept here.

# Audio session and engine recovery (iOS only)

The two files here are the iOS counterpart of `Audio/Mac/Devices/`: what answers when the system moves the audio out from under the engine, which on iOS is the carrier of Vibe's render pipeline (`Audio/CLAUDE.md`). The internal `(RecoveryInternal)` category owns the iOS carrier; `(Recovery)` receives the session controller’s recovery verdicts.

## AudioSessionController

The `AVAudioSession` half of what `AudioPlayer+Devices` is on macOS.

**The playback category is activated before every play, never at launch**, and released with `NotifyOthersOnDeactivation` once playback sits idle past the engine's own idle stop — so an interrupted podcast gets its resume hint.

**Not activating is not enough on its own, which is what `prepareIdleCategory` exists for.** `AVAudioEngine` instantiates its output unit while its source node is wired — `AudioPlayer`'s `createOutputOnQueue`, on the player's queue moments after launch — and that runs against whatever category the session carries, activating it without anyone asking. The system default is SoloAmbient, which is not mixable, so the engine's construction alone stopped whatever else the device was playing: at a cold launch only, since the carrier is built once, and with Vibe itself silent. Parking the mixable Ambient category first makes that implicit activation claim nothing. `PlaybackController` calls it above the player's own creation, and the ordering is the whole point — it cannot move down beside the controller's construction, which happens after.

Four events, four delegate verdicts, each mapped onto the player's public API:

| Event | Verdict |
| --- | --- |
| Interruption Began / Ended | pause, then resume |
| Route loss (`OldDeviceUnavailable`) | pause |
| Engine configuration change | classify the output transition, then pause or `recoverFromEngineConfigurationChange` |
| Media services reset | `beginMediaServicesResetWithCompletion:` at notification receipt |

**Was-playing is captured at the interruption's Began edge *only*.** The configuration-change and route-loss pauses that pile up mid-interruption must not overwrite it, or the resume decides from the wrong state.

**Interruption-ended automatic activation is not user intent.** It preserves and checks the route-loss and media-reset blockers before and after the synchronous session activation, so unplugging headphones during a call cannot turn the system's `ShouldResume` hint into playback on the speaker. Only explicit user activation clears those persistent blockers.

The configuration-change verdict restarts the stopped engine **in place**, so connecting AirPods or CarPlay keeps playing rather than pausing. It does not guess at notification timing: the controller records whether the last and current outputs are built-in, external or absent. An external-to-built-in transition is headphone loss and pauses even when the engine-configuration notification arrives first; an already recorded route loss, interruption or media reset blocks recovery until a successful explicit session activation. Ordinary configuration changes are generation-coalesced before main delivery.

**The three verdicts above are decided in a header, not in the controller.** `AudioSessionRecoveryRules.h` — header-only, Foundation-only, tested — holds `VibeAudioSessionConfigurationAction` (restart in place, or park because the output is disappearing), `VibeAudioSessionMayDeliverConfigurationRecovery` (a later notification coalesces an earlier ordinary restart; any safety verdict received before main delivery blocks it) and `VibeAudioSessionMayAutomaticallyResume` (interruption-ended is a system suggestion, not a fresh user play). Existing interruption, route-loss and reset ownership always wins in all three, which is what makes the rules fail-closed.

**One scan classifies a route, and two things read the result.** `OutputRouteRules.h` — header-only, Foundation-only, tested — holds the fine kind the card's indicator draws (speaker, receiver, wired, Bluetooth, AirPlay, CarPlay, other, none) and the fold onto the coarse none/built-in/external kind the pause/recover decision above is written in terms of. Deriving one from the other is what stops a newly handled port from being external to the indicator and built-in to the unplugged-headphones rule. The `portType` mapping stays in `AudioSessionController.m`: the `AVAudioSessionPort*` constants are AVFoundation's API, and re-spelling their values into the header would depend on their contents.

**The route pair — kind and the system's device name — is published on a real change and nowhere else.** `recordOutputRoute:name:` writes both beside `_lastOutputRoute` under the one lock, so the pair and the fold can never describe two different routes, and returns whether anything moved. Init records without publishing (the delegate is set, but `PlaybackController` is still inside its own init); `activateSession` publishes on change, which is the edge where a destination picked against an inactive session — that posts no route notification of its own — first becomes visible; `handleRouteChange:` publishes outside the loss branch, because a new device, an override and a category change are exactly what an indicator exists for. The hop is an unconditional `dispatch_async`, not `onMain:`: this edge fans out to every `PlaybackObserver`, and `activate` calls it from inside an activation the play path is waiting on. **Before the first activation the session can report no outputs at all**, which is `None` — a real answer, not an error.

**A pause verdict during Loading parks the landing** rather than being dropped. The player's explicit `pause`/`resume` methods update the pending request to the requested state, so duplicate system verdicts are no-ops instead of toggles.

## AudioPlayer+Recovery

The player's engine-recovery category, on `AudioPlayerInternal.h`'s shared private surface exactly as the mac's `AudioPlayer+Devices` is. It lives here so the mac target never compiles or even sees the API, and `AudioSessionController`'s verdicts are the only callers.

- `recoverFromEngineConfigurationChange` — restarts a stopped engine in place, preserving the play state across route changes at the pipeline's rate. The current voice kept its ring and gain across the stop, so nothing is rescheduled and the position needs no cache: it is the voice's own consumed count. A route at **another sample rate** is followed instead (`followOutputFormatOnQueue:`, `Audio/CLAUDE.md`): the source node and the bus are rebuilt at it and the track kept at its position and state, so the bus converts once, at the route's rate, and the output node converts nothing. **The same follow runs before every engine start** — a resume, a play's settlement — through `followOutputRouteOnQueue`, because a route loss or an interruption blocks this recovery until an explicit activation, and the next start would otherwise run the engine on the stale rate with the output node resampling. A restart that fails parks the track Paused and says so.
- `beginMediaServicesResetWithCompletion:` — **every audio object is dead per Apple's contract**, so this drops them without messaging them (`dropEngineBoundStateOnQueue`: the master bus's gate closes, the bus and the meter are retired through `afterRenderLeavesOnQueue:` and the engine is released) and `createOutputOnQueue` recreates the carrier — one source node whose render block calls `VibeMasterBusRender`, wired to the output node; nothing hosted exists on iOS to dispose. It is called synchronously on the notification thread: reset receipt and play submission each enqueue under the same state lock, so a play received after reset runs on the new engine instead of being destroyed by a later main-thread rebuild. The recovery position is read from the voice's counter before the bus is dropped, never by messaging the invalid file or engine. `createOutputOnQueue` is shared with ordinary init, so the rebuild is the launch shape. Its main-thread completion runs only after Stopped is authoritative and only if no newer play submission superseded the reset; `PlaybackController` then publishes that state and re-parks the captured track.

## Verifying

The simulator exercises none of this faithfully. Interruptions, route changes (headphone unplug), background audio past lock, the lock-screen card and whether a cold launch leaves another app's audio playing all need a real device.

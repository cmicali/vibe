# Audio session and engine recovery (iOS only)

The two files here are the iOS counterpart of `Audio/Mac/Devices/`: what answers when the system moves the audio out from under the engine. Nothing here touches the graph directly.

## AudioSessionController

The `AVAudioSession` half of what `AudioPlayer+Devices` is on macOS.

**The playback category is activated before every play, never at launch**, and released with `NotifyOthersOnDeactivation` once playback sits idle past the engine's own idle stop — so an interrupted podcast gets its resume hint.

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

**A pause verdict during Loading parks the landing** rather than being dropped. The player's explicit `pause`/`resume` methods update the pending request to the requested state, so duplicate system verdicts are no-ops instead of toggles.

## AudioPlayer+Recovery

The player's engine-recovery category, on `AudioPlayerInternal.h`'s shared private surface exactly as the mac's `AudioPlayer+Devices` is. It lives here so the mac target never compiles or even sees the API, and `AudioSessionController`'s verdicts are the only callers.

- `recoverFromEngineConfigurationChange` — restarts a stopped engine in place at the cached position, preserving the play state across route and format changes. An iOS-only player-queue sampler refreshes that cache from valid render time while the backgrounded UI timer is dormant.
- `beginMediaServicesResetWithCompletion:` — **every audio object is dead per Apple's contract**, so this drops them without messaging them (`dropEngineBoundStateOnQueue`) and recreates the engine and master bus. It is called synchronously on the notification thread: reset receipt and play submission each enqueue under the same state lock, so a play received after reset runs on the new engine instead of being destroyed by a later main-thread rebuild. The recovery position is copied only from the lock-protected last-valid cache, never by messaging the invalid file, node or engine. `installMasterBusOnQueue` is shared with ordinary init, so the FX and no-FX configurations rebuild identically — and since the iOS player is created with `enableFX:NO`, it takes the bare mixer-to-output wire. Its main-thread completion runs only after Stopped is authoritative and only if no newer play submission superseded the reset; `PlaybackController` then publishes that state and re-parks the captured track.

## Verifying

The simulator exercises none of this faithfully. Interruptions, route changes (headphone unplug), background audio past lock and the lock-screen card need a real device.

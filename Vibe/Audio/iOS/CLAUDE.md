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
| Engine configuration change | `recoverFromEngineConfigurationChange` |
| Media services reset | `reinitializeAfterMediaServicesReset` |

**Was-playing is captured at the interruption's Began edge *only*.** The configuration-change and route-loss pauses that pile up mid-interruption must not overwrite it, or the resume decides from the wrong state.

The configuration-change verdict restarts the stopped engine **in place**, so connecting AirPods or CarPlay keeps playing rather than pausing.

**A pause verdict during Loading parks the landing** rather than being dropped — `playPause` toggles `_pendingStartPaused` while Loading — so the engine never starts against an interrupted session.

## AudioPlayer+Recovery

The player's engine-recovery category, on `AudioPlayerInternal.h`'s shared private surface exactly as the mac's `AudioPlayer+Devices` is. It lives here so the mac target never compiles or even sees the API, and `AudioSessionController`'s verdicts are the only callers.

- `recoverFromEngineConfigurationChange` — restarts a stopped engine in place at the cached position, preserving the play state across route and format changes.
- `reinitializeAfterMediaServicesReset` — **every audio object is dead per Apple's contract**, so this drops them without messaging them (`dropEngineBoundStateOnQueue`) and recreates the engine and master bus. `installMasterBusOnQueue` is shared with the ordinary init, so the FX and no-FX configurations rebuild identically — and since the iOS player is created with `enableFX:NO`, it takes the bare mixer-to-output wire. `PlayerViewController` re-parks the current track at the captured position.

## Verifying

The simulator exercises none of this faithfully. Interruptions, route changes (headphone unplug), background audio past lock and the lock-screen card need a real device.

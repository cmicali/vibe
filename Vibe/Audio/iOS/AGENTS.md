# Audio session and output recovery (iOS only)

The iOS counterpart of `Audio/Mac/Devices/`: what answers when the system moves the audio out from under the output. The render is pulled by the same `AudioOutputUnit` on both platforms (`Audio/AGENTS.md`), a RemoteIO unit here. This directory implements the shared `(PlatformOutput)` declaration in `AudioPlayerInternal.h` for iOS. `(Recovery)` receives the session controller's recovery verdicts.

## AudioSessionController

The `AVAudioSession` half of what `AudioPlayer+Devices` is on macOS.

**The playback category is activated before every play, never at launch.** It is released with `NotifyOthersOnDeactivation`, so an interrupted podcast gets its resume hint. **It is released once the player's output has actually stopped, never on a timer of the session's own.** The release is one rule, `VibeAudioSessionMayDeactivate` (`AudioSessionRecoveryRules.h`), over three facts read when it is asked:

- a pause or end asked for it, and no `activate` has reclaimed the session since (`deactivateWhenIdle`);
- no interruption is in progress;
- `AudioPlayer.outputIdle`.

It is asked at each edge that can complete it. The request itself releases at once under an output that never started. The player's idle edge asks (`audioPlayerOutputDidBecomeIdle:` → `deactivateIfIdle`), and so does an interruption's Ended with no resume. The idle stop is the player's and waits out an FX tail (`Audio/AGENTS.md`), which no timer here can know. **TRAP: `setActive:NO` answering NO is not a refusal.** With audio objects running, the session goes inactive anyway and stops them. **TRAP: the idle stop's unit stop is only queued**, so `releaseIdleOutputUnitOnQueue` waits the unit's queue out before idle is published.

**A buffering hold keeps the output running, by construction.** The hold is the pause's ramp with the transport left Playing (`Audio/AGENTS.md`). The idle stop is armed only on a pause or stop, and stops nothing unless the state is still Paused or Stopped. So RemoteIO keeps pulling silence and the session stays active while a stream buffers. A backgrounded app keeps the audio that keeps it from suspension, and the download with it. The stall is a real pause, so its idle stop follows six seconds later and the session releases. On a device, check a hold with the screen locked: the `Buffering:` line's held time against `dump_state.player` (`state` playing, `buffering` 1), and no `AudioOutputUnit: stop` or `AudioSession: deactivated` line.

**No output unit exists before the first play.** Launch sets the pipeline's format from the session's rate and hosts the enabled FX, which claim no output. The RemoteIO unit is made at the first output start, after the play activated the session. A unit made at launch would take the session's default SoloAmbient category, which is not mixable and stops whatever else the device is playing.

Four events, four delegate verdicts, each mapped onto the player's public API:

| Event | Verdict |
| --- | --- |
| Interruption Began / Ended | pause, then resume |
| Route loss (`OldDeviceUnavailable`) | pause |
| Any other route change | classify the output transition, then pause or `recoverOutput` |
| Media services reset | `beginMediaServicesResetWithCompletion:` at notification receipt |

**An interruption whose reason is route-disconnected is a pause and nothing else.** No Ended follows it (AirPods into their case), so it sets neither the in-progress flag nor the interruption blocker. The route loss beside it owns the blocker.

**Was-playing is captured at the interruption's Began edge *only*.** The route-loss pauses that pile up mid-interruption must not overwrite it, or the resume decides from the wrong state.

**Interruption-ended automatic activation is not user intent.** It checks the route-loss and media-reset blockers before and after the session activation. So unplugging headphones during a call cannot turn the system's `ShouldResume` hint into playback on the speaker. Only an explicit user activation clears those blockers.

**The route-change notification is the only output trigger.** RemoteIO keeps running across a route change that brings a device in, converting to the new hardware rate itself. **A route that loses its device is different: iOS stops the unit itself**, about 0.75 s after the change. That stop reaches the player through the system-stop path below, after the route-loss verdict has already paused. So the unit is not guaranteed to survive a route change. For a device coming in, the recovery verdict has the pipeline follow the route's rate, so the bus's conversion stays the only one. The controller records whether the last and current outputs are built-in, external or absent. An external-to-built-in transition is headphone loss and pauses, whatever reason the notification carried. A recorded route loss or media reset blocks recovery until a successful explicit activation. An interruption blocks it until its end or such an activation. Ordinary recoveries are generation-coalesced before main delivery.

**The verdicts are decided in a header, not in the controller.** `AudioSessionRecoveryRules.h` is header-only, Foundation-only and tested. It holds:

- `VibeAudioSessionConfigurationActionForRoutes`: recover on the new route, park because the output is disappearing, or ignore while an interruption, route loss or reset owns the output;
- `VibeAudioSessionMayDeliverConfigurationRecovery`: a later route change coalesces an earlier ordinary recovery, and any safety verdict received before main delivery blocks it;
- `VibeAudioSessionMayAutomaticallyResume`: interruption-ended is a system suggestion, not a fresh user play.

Existing interruption, route-loss and reset ownership wins in all three, which makes the rules fail-closed.

**One scan classifies a route, and two things read the result.** `OutputRouteRules.h` (header-only, Foundation-only, tested) holds the fine kind the card's indicator draws (speaker, receiver, wired, Bluetooth, AirPlay, CarPlay, other, none). It also holds the fold onto the coarse none/built-in/external kind the pause/recover decision uses. Deriving one from the other stops a new port from being external to the indicator and built-in to the headphones rule. The `portType` mapping stays in `AudioSessionController.m`, since the `AVAudioSessionPort*` constants are AVFoundation's. **A Bluetooth route's glyph is guessed from its device name**, because no public API says what the device is (`docs/not-doing/rejected-alternatives.md`). An unrecognised name draws the generic glyph.

**The route pair (kind and the system's device name) is published on a real change and nowhere else.** `recordOutputRoute:name:` writes both under one lock, so the pair never describes two routes, and returns whether anything moved. Init records without publishing, since `PlaybackController` is still inside its own init. `activateSession` publishes on change: a destination picked against an inactive session posts no route notification and first shows here. `handleRouteChange:` publishes whatever its verdict. **TRAP:** the hop is an unconditional `dispatch_async`, not `onMain:`. This edge fans out to every `PlaybackObserver`, and `activate` calls it from inside an activation the play path waits on. **Before the first activation the session can report no outputs at all**, which is `None`, a real answer.

**A pause verdict during Loading parks the landing** rather than being dropped. The player's `pause`/`resume` update the pending request to the requested state, so duplicate system verdicts are no-ops, not toggles.

## AudioPlayer+Recovery

The player's output-recovery category. `AudioPlayerInternal.h` imports its header on iOS, where the mac imports `AudioPlayer+DevicesInternal.h`. It lives here so the mac target never sees the API. `PlaybackController` calls it for `AudioSessionController`'s verdicts. It also calls `recoverOutput` after the remote Play command's resume (`PlaybackController+NowPlaying.m`).

**The system stops the unit under the app, and says so only through the unit.** An interruption stops RemoteIO without asking. `AudioOutputUnit`'s `IsRunning` listener reports a stop it sees with the gate open (the player's own stops close the gate first) through `failureHandler` without an error. **TRAP:** RemoteIO reports on a thread of its own, and removing its listener does not wait for a report in flight. So the listener's refCon is a token the unit is looked up by, weakly, and the reference that lookup takes is dropped on the unit's queue, never inside RemoteIO's callback (`AudioOutputUnit.m`). The player stops its output at that edge (`outputUnitFailedOnQueue:`), so the liveness fold and the drain timer follow at once and the next start is an ordinary one. What the transport does is the session verdict's. **TRAP: the stop itself never pauses.** It can land a millisecond before its interruption's Began, whose was-playing the Ended resume depends on. **A stop no verdict follows pauses after a second.** iOS stops the unit seconds before it delivers a media-services reset, with no interruption. Playing would otherwise be published over a dead output until the notification came.

- `recoverOutput` is for a playing voice only, since every start follows the route itself. It follows the route's rate, then restarts a unit the system stopped. A route at **another sample rate** is followed through `followOutputFormatOnQueue:` (`AudioPlayer+Pipeline.h`). The unit and the bus are rebuilt at it, with the track kept at its position and state, so RemoteIO converts nothing. Otherwise a stopped unit under a Playing voice restarts in place: the voice kept its ring and gain, so nothing is rescheduled. **The same follow runs before every output start** (`followOutputRateOnQueue`), because a route loss or an interruption blocks recovery until an explicit activation. Without it the next start would run on the stale rate with RemoteIO resampling. A restart with no unit to make parks the track Paused (`didPausePlaying:`). A start the unit refuses later parks it too and reports the error (`outputUnitFailedOnQueue:`).
- `beginMediaServicesResetWithCompletion:`: **every audio object is dead per Apple's contract**, so the player drops them without messaging them. `dropOutputBoundStateOnQueue` closes the master bus's gate and retires the bus, meter and FX hosting through `afterRenderLeavesOnQueue:`. It marks the FX units dead even while bypassed, and marks `_outputUnit` dead and releases it. A late failure from it never matches the next unit's run generation. A dead unit closes its gate and supersedes any queued start. Its queued configure and stop, and its dealloc, no longer message the instance, and the dealloc only disposes it. `createOutputOnQueue`, shared with init, then rebuilds the launch shape. **TRAP:** the reset is called synchronously on the notification thread. Reset receipt and play submission each enqueue under the same state lock, so a play received after the reset runs on the new output (`AudioPlayer+Recovery.m`). The recovery position is read from the voice's counter before the bus is dropped. Its main-thread completion runs only after Stopped is authoritative and only if no newer play superseded the reset. `PlaybackController` then publishes that state and re-parks the captured track.

## Verifying

The simulator exercises none of this faithfully. These need a real device: interruptions (ended with and without `ShouldResume`), route changes (headphone and Bluetooth plug and unplug, playing and paused, with a rate follow), media-services reset, background audio past lock, the lock-screen card, and whether a cold launch leaves another app's audio playing. Two route cases have not been seen live: one that keeps playing and has iOS stop the unit, and a rate follow mid-playback. On a device, a media-services reset stops the unit seconds (3.8–6.5 s) before its notification. The render clock stalls inside the system ~0.7 s after an interruption's resume, and 0.2–1.8 s on a route move, with nothing of the app's in the stack. The device loop is log-only, so every edge here logs: the session's activation and release, a release held and why, each interruption edge with its reason, the route verdicts, and the unit's starts, stops and system stops.

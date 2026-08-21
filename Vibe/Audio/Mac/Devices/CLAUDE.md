# Output devices (macOS only)

The CoreAudio HAL output-device layer: `AudioDevice`, `AudioDeviceManager`, `CoreAudioUtil`, and `AudioPlayer+Devices`. The iOS counterpart is `Audio/iOS/`, which is an `AVAudioSession` and nothing like this.

## AudioDeviceManager

A singleton that owns device-change listening. At init it registers CoreAudio listeners for the default output device and the device list, kept for the life of the process, then performs a post-registration sweep. `outputDevices` serves the latest immutable snapshot and waits at most 250ms for the first one on every calling thread; an unavailable `coreaudiod` therefore cannot strand a caller's serial queue.

**A snapshot is normally published only after every read agrees** — the device list, the system default, and each device's output-channel, name and UID properties, plus the default appearing in the resulting list. A partial result keeps the prior snapshot and takes the retry path rather than looking like device removal, so legitimate empty results stay representable while a transient HAL failure cannot persist a false System Output fallback.

**But strictness is bounded, because a persistent failure is not a transient one.** A virtual or aggregate driver that always fails a property read, a device with an empty name, or a default device that enumerates with no output channels would otherwise keep *every* device unpublished for the life of the process: the two-second retry never stops, the Output menu never populates, and `resolveOutputDeviceForUID:` never completes, so the saved device can never bind. After `kMaxIncompleteSweeps` (3) consecutive refusals one sweep publishes what it could read, omitting the devices that failed, and logs that it did. The three inputs with no partial form — the list, its size, and the system default — still return nil however many sweeps have failed.

**TRAP: absence in `outputDevices` is not removal.** It answers `@[]` both for "no output devices exist" and for "no sweep has been published yet", which is what the 250ms ceiling returns during setup or while a failure is retrying. Every decision that treats absence as removal — and so falls back to System Output *and persists it* — asks `knowsOutputDeviceIsAbsent:` instead, which answers NO until there is a real snapshot to be absent from. Both callers are in `AudioPlayer+Devices`: the device-list observer and `handleEngineConfigurationChange`, the latter mattering most because it is driven by `AVAudioEngine` rather than by this class and can therefore arrive before any snapshot exists.

Saved-device discovery does not use that synchronous getter. `resolveOutputDeviceForUID:name:completion:` waits asynchronously for the first successful snapshot, UID first and name as compatibility fallback. `AudioPlayer` starts honestly on System Output and retains an unmatched saved preference. A match is applied only while the player is Stopped and only committed after the HAL bind succeeds; if playback wins the lookup race, the intent stays pending for the next Stopped transition or device/default refresh. Discovery never occupies the player's sole queue while CoreAudio is unavailable.

**TRAP: never call `outputDevices` from `_refreshQueue`.** Setup runs there, so a call from that queue before setup completes pointlessly consumes the getter's full 250ms wait ceiling on work that cannot advance until the call returns.

`refreshOutputDevicesCache` runs only on that serial refresh queue, which orders the stores, so a newer sweep can never be overwritten by an older one.

**Observers are fanned out on the main thread in the common run-loop modes**, not with a plain `dispatch_async` — GCD main-queue blocks do not run during menu tracking, and this way the devices menu refreshes while it is open. Observers (`AudioDeviceManagerObserver`) are held weakly: `AudioPlayer` and `OutputDevicesMenuController`.

## AudioPlayer+Devices

All device management on this platform: resolution, switching, config-change recovery, and parking or falling back when a device vanishes. It is a category on `AudioPlayerInternal.h`'s shared private surface, exactly as the iOS `AudioPlayer+Recovery` is, and is declared in `AudioPlayer.h` beside `(State)`.

The player's async init asks the manager to resolve the saved output device — **by UID first and name as fallback** — without blocking the player queue. Until a successful bind, `currentlyRequestedAudioDeviceId` stays `-1` and the saved preference remains pending rather than reporting an explicit device that was never selected.

**Where that deferred bind may land is `VibeCanBindSavedOutputDevice`: Stopped, or Loading while the engine is not running.** Stopped alone was not enough — launching by double-clicking a file starts an open within milliseconds of the async init, so the *first* track would play through the system default and only move to the saved device at the next track boundary. At launch nothing is rendering, so the rebind is inaudible and the in-flight open starts itself on the new device. **TRAP: an ordinary mid-session track change is also Loading**, with the outgoing node still fading out on a running engine, and rebinding there would stop the engine under that fade and click — which is why the engine check is part of the rule rather than a comment about launch. Playing and Paused are excluded outright: a failed bind there tears down live playback.

`didChangeOutputDevice:` is sent on **every** settled mutation, not only when the id moved. The delegate both persists the choice and drives the menu checkmark and is idempotent, so re-announcing an unchanged value is free; suppressing it made "Settings names the last committed device" an invariant nothing enforced, and any path that left the two disagreeing could never resynchronize them, because the one call that writes Settings was skipped exactly when they already looked equal.

An explicitly bound device that later disappears, whether mid-playback or while idle, falls back to System Output, and the fallback is persisted. An absent launch preference instead remains pending. A failed explicit concrete-device bind preserves that pending preference because Settings still names it; a successful explicit bind supersedes it. Explicit System Output always clears it, even when `currentlyRequestedAudioDeviceId` is already `-1`, because `-1` is the durable policy to follow whatever system default exists now or later. A failed system-default property read does not park playback as though no output existed; one coalesced retry follows, then a real device/default notification must provide the next attempt. The menu's checkmark tracks `currentlyRequestedAudioDeviceId`; the menu itself is `Mac/Menu/`.

A device switch stops the node, so it must clear the armed gapless splice first and re-arm after its reschedule — see `Audio/CLAUDE.md`.

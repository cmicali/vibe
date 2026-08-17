# Output devices (macOS only)

The CoreAudio HAL output-device layer: `AudioDevice`, `AudioDeviceManager`, `CoreAudioUtil`, and `AudioPlayer+Devices`. The iOS counterpart is `Audio/iOS/`, which is an `AVAudioSession` and nothing like this.

## AudioDeviceManager

A singleton that owns device-change listening. At init it registers CoreAudio listeners for the default output device and the device list, kept for the life of the process, then performs a **mandatory post-registration sweep** before releasing the first off-main `outputDevices` caller — no startup change can fall between the first snapshot and listener coverage.

That wait is unbounded off the main thread (the launch-time caller is `AudioPlayer`'s async init, on its own queue) but briefly bounded on it (`kListenerSetupMainThreadWait`): the getter is on the Output menu's update path, and a wedged `coreaudiod` must not beachball the app. Rendering one snapshot early is the lesser evil, and by then can only happen in the sub-100ms window before setup lands.

**TRAP: never call `outputDevices` from `_refreshQueue`.** Setup runs there, so a call from that queue before setup completes waits on a block that can no longer run.

`refreshOutputDevicesCache` runs only on that serial refresh queue, which orders the stores, so a newer sweep can never be overwritten by an older one.

**Observers are fanned out to on the main thread in the common run-loop modes**, not with a plain `dispatch_async` — GCD main-queue blocks do not run during menu tracking, and this way the devices menu refreshes while it is open. Observers (`AudioDeviceManagerObserver`) are held weakly: `AudioPlayer` and `OutputDevicesMenuController`.

## AudioPlayer+Devices

All device management on this platform: resolution, switching, config-change recovery, and parking or falling back when a device vanishes. It is a category on `AudioPlayerInternal.h`'s shared private surface, exactly as the iOS `AudioPlayer+Recovery` is, and is declared in `AudioPlayer.h` beside `(State)`.

The player's async init resolves the saved output device on the player queue — **by UID first and name as fallback** — which keeps device enumeration off the launch path's main thread.

An explicitly chosen device that disappears, whether mid-playback, while idle or at launch, falls back to System Output, and the fallback is persisted. The menu's checkmark tracks `AudioPlayer.currentlyRequestedAudioDeviceId`; the menu itself is `Mac/Menu/`.

A device switch stops the node, so it must clear the armed gapless splice first and re-arm after its reschedule — see `Audio/CLAUDE.md`.

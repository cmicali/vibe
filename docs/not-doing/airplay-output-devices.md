# Future: AirPlay targets as output devices (macOS)

Written 2026-08-22. **Investigated and declined** — see the verdict below. Nothing in the repo has changed for it. The file:line anchors are against `main` at `c670e49` **with its uncommitted working tree**; re-check every anchor before acting.

## The verdict, first

**This is very unlikely to be implemented.** Two reasons, and the second is the real one:

1. **You can already play through AirPlay from Vibe today, with no code at all.** Pick the AirPlay target in the menu-bar Sound picker or Control Center. macOS routes system audio to it and makes it the default output, and Vibe — sitting on **System Output**, which is the shipped default — follows it. Music comes out of the HomePod. The feature request is not "make AirPlay work"; it already works.
2. **Adding it to Vibe's own device list goes against the mission to stay light, simple and fast.** The only way to name targets inside Vibe is a Bonjour browse, which costs the `com.apple.security.network.client` entitlement and a macOS 15+ **Local Network** permission prompt — a first for an app that today prompts for nothing but file access. And after all that, clicking a target still cannot connect it (see below): the best possible flow is "click the row in Vibe, then pick it again in the system picker". Two steps, one permission prompt, one new framework, to replace something the menu bar already does in one click.

The rest of this file is the research, so nobody has to redo it.

## The question this started from, and its answer

*Can AirPlay targets be listed as Vibe output devices, in their own section below the system outputs?*

**No** — and it is a platform no, not a hard problem. Vibe can *group* the AirPlay devices macOS has already created. It cannot discover an unrouted target, and it cannot connect one.

## The evidence

Probed on macOS 26.5.2 (build 25F84), 2026-08-22, with nothing routed to AirPlay:

```bash
perl -e 'alarm 6; exec @ARGV' dns-sd -B _airplay._tcp local
```

Finds **8 targets** on the LAN — `sawtooth`, `squarewave`, `Living Room`, `Living Room (2)`, `Kitchen`, `Pool`, `Home Theater`, `Master Bedroom` — and `_raop._tcp` confirms every one of them is an audio receiver.

```bash
system_profiler SPAudioDataType
```

Reports **3 CoreAudio devices**: `cmicali iPhone Microphone`, `MacBook Pro Microphone`, `MacBook Pro Speakers`. A direct `AudioObjectGetPropertyData(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, …)` agrees, and their `kAudioDevicePropertyTransportType` values read cleanly as `ccwd` (Continuity) and `bltn` (built-in).

**Not one of the eight AirPlay targets is in the HAL.**

The 10.10-era workaround is also gone. `kAudioHardwarePropertyTranslateUIDToDevice` with UID `"AirPlay"` returns `noErr` and `kAudioObjectUnknown` — the pseudo-device whose `kAudioDevicePropertyDataSources` used to enumerate each target no longer exists. That mechanism was removed in 10.11 (Apple Developer Forums thread 17664, rdar://23049205) and 26.5 confirms it stayed removed.

## Where the API stops

macOS instantiates an AirPlay HAL device **only when the system itself routes to a target**, from Control Center ▸ Sound or Sound settings. Nothing an app can call brings one into existence:

- `kAudioHardwarePropertyDevices` is the entire enumeration surface. There is no "discovered but not instantiated" concept, no browse, no connect.
- `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultOutputDevice`, and `AudioUnitSetProperty` with `kAudioOutputUnitProperty_CurrentDevice` — the one Vibe already uses in `setOutputUnitDevice:` (`Vibe/Audio/Mac/Devices/AudioPlayer+Devices.m:132`) — both take an existing `AudioDeviceID`. Neither can conjure one.
- `AVRoutePickerView` is public on macOS 10.15+, but its `player` property is `AVPlayer *` and **macOS-only** — the whole class is built around routing an `AVPlayer`, and there is no bridge from it to an `AVAudioEngine` graph. Apple's own forum threads report it not affecting playback when a route is chosen (744128) and `volume` ceasing to function over AirPlay (698988, where the only reply was an Apple media engineer asking whether an enhancement request had been filed).
- `AVRouting` / `AVCustomRoutingController` exists for **third-party, non-AirPlay** routes. Wrong tool.
- WWDC23's "Tune up your AirPlay audio experience" is `AVAudioSession`-shaped and says nothing about macOS.

## Dead ends, so they are not re-explored

- **The `"AirPlay"` pseudo-device plus `kAudioDevicePropertyDataSources`.** The macOS 10.10 model, where one HAL device's data sources were the targets. Removed in 10.11; the probe above confirms it is still gone in 26.5.
- **`AVRoutePickerView` fed a dummy `AVPlayer`.** Routes that player, not Vibe's engine. And on macOS it is reported not to route reliably even then.
- **Bonjour discovery on its own.** `NWBrowser` over `_airplay._tcp` names every target cheaply and asynchronously — that half genuinely works. It cannot connect one, so the rows would be decorative. A greyed-out "Kitchen" that does nothing when clicked is worse than no row at all.
- **Implementing RAOP / AirPlay 2 as a sender inside Vibe.** AirPlay 1 depends on Apple's leaked RSA key; AirPlay 2 needs SRP pairing, Curve25519 and ChaCha20-Poly1305. Not shippable in the Mac App Store, and vastly outside a light native player. Closed.

## What already works today, with no code at all

This is half the verdict, so it is worth spelling out precisely.

Vibe's "System Output" is not a device — it is a **durable policy**, `currentlyRequestedAudioDeviceId == -1`, meaning *follow whatever the system default is now or later* (`Vibe/Audio/Mac/Devices/CLAUDE.md`). When macOS routes to an AirPlay target it creates the HAL device and makes it the default; `AudioDeviceManager`'s `kAudioHardwarePropertyDefaultOutputDevice` listener fires, `systemDefaultOutputDeviceDidChange` (`AudioPlayer+Devices.m:29`) sees the requested id is `-1`, and re-pins the output unit to the new default. Playback moves to the HomePod.

**The one wrinkle worth knowing:** a device the user pinned *explicitly* does not follow the default — by design, and correctly. So the "AirPlay just works" story holds only while Vibe is on System Output, which is the shipped default and where most users will be.

## What building it would involve, if the verdict ever changes

Three separable pieces, in increasing cost. The first two are defensible on their own; the third is the one that fails the mission test.

### 1. Transport-type sectioning — the only cheap part

New `readTransportType:forDeviceID:` in `Vibe/Audio/Mac/Devices/CoreAudioUtil.m`, following that file's convention of returning `BOOL` success separately from the answer (see `readUID:forDeviceID:` at `:32`, `readName:forDeviceID:` at `:63`, `readHasOutputChannels:` at `:96`). A new `transportType` field on `AudioDevice` — today exactly four readonly properties, `name`/`uid`/`deviceId`/`isSystemDefault` (`AudioDevice.h:20-25`), with `isEqual:`/`hash` keyed on `deviceId` alone, which stays true.

**TRAP: transport must not join the strict-sweep rule.** `enumerateOutputDevicesAcceptingPartial:` (`AudioDeviceManager.m:391`) discards a device outright when `readHasOutputChannels:` or `readDeviceForID:defaultID:device:` (`:524`) fails, and marks the whole sweep incomplete — which then keeps the prior snapshot and retries, up to `kMaxIncompleteSweeps` (`:35`). Transport is an *optional refinement*, not an identity: a failed read must degrade to "unknown transport, main section", or a driver with no transport property newly vanishes from a list it appears in today.

**On the performance requirement:** this is one extra `AudioObjectGetPropertyData` per device per sweep, on `_refreshQueue`, off main, inside a sweep that already does three-to-four reads per device. It is not measurable. The enumeration cost worth worrying about is not here — it is the Bonjour browse in piece 3.

### 2. The sectioned list

`Vibe/Mac/Menu/OutputDevicesMenuController.m` `menuNeedsUpdate:` (`:59`) is the **single builder**, driving both surfaces: the menu-bar Output menu (`MainMenuBuilder.m`, which sets the controller as the menu's delegate) and the Settings ▸ General popup (`SettingsGeneralViewController.m:51`, `refreshOutputPopUp` at `:138` calling `menuNeedsUpdate:` on the popup's own menu). One change moves both, which is the good news.

The bad news is the arithmetic. The in-place resize is hardcoded to a **2-item prefix** — System Output at tag `-1`, then one separator — at `:76`, `:81`, `:95-98`. A second section changes that in one place, and the rebuild must stay in-place: it deliberately resizes rather than rebuilds so an *open* menu refreshes without losing tracking (which is also why `AudioDeviceManager` fans observers out with `CFRunLoopPerformBlock` in the common modes rather than `dispatch_async`).

The repo has **no `NSMenuItem` section headers anywhere today**, so an "AirPlay" header is a new idiom, and it has to render acceptably in both an `NSMenu` and an `NSPopUpButton`. New strings beside `STR_MENU_OUTPUT*` (`Vibe/Common/VibeStrings.h:167-169`), then `make strings`.

Note what this piece does and does not buy: it groups AirPlay devices **that already exist**, which is to say only after the user routed to one from Control Center — at which point it is already the system default and Vibe is already playing through it. The section would usually hold exactly one device, the one currently selected. That is a thin deliverable.

### 3. Discovery and handoff — the part that fails the mission test

`NWBrowser` over `_airplay._tcp`, **on demand only**: started when the Output menu opens (`menuWillOpen:`) or the Settings pane appears, stopped on close. Nothing runs at launch, and the permission prompt lands the first time the user goes looking for output devices, which is at least the moment it makes sense.

Costs:

- `com.apple.security.network.client` in `Vibe/Mac/App/Vibe.entitlements`, which today holds only `com.apple.security.assets.music.read-write` and `com.apple.security.files.bookmarks.app-scope`.
- The macOS 15+ **Local Network** prompt — "Vibe would like to find devices on your local network".
- A new framework dependency in `project.yml`.

And the payoff is a row that cannot be acted on. The best available flow is: click "Kitchen" in Vibe → Vibe opens `x-apple.systempreferences:com.apple.Sound-Settings.extension` → the user picks Kitchen *again* → Vibe's device-list listener sees the new AirPlay HAL device appear and auto-binds and persists it. That final auto-bind is genuinely nice, and it is not enough to justify the rest.

## Files, if it were ever built

- `Vibe/Audio/Mac/Devices/CoreAudioUtil.{h,m}` — `readTransportType:forDeviceID:`.
- `Vibe/Audio/Mac/Devices/AudioDevice.{h,m}` — the `transportType` field; `isEqual:`/`hash` stay `deviceId`-only.
- `Vibe/Audio/Mac/Devices/AudioDeviceManager.m` — the sweep at `:391` and `readDeviceForID:` at `:524`, with the "optional refinement, never discards" rule above.
- `Vibe/Audio/Mac/Devices/CLAUDE.md` — the sweep's strictness paragraph names exactly which reads are load-bearing; a new optional read has to be named there as optional.
- `Vibe/Mac/Menu/OutputDevicesMenuController.m` — `menuNeedsUpdate:` and the prefix arithmetic.
- `Vibe/Mac/Settings/SettingsGeneralViewController.m` — nothing, if the section is built in the shared builder. Verify the popup renders a header item.
- `Vibe/Common/VibeStrings.h` — the section titles; `make strings` after.
- `Vibe/Mac/App/Vibe.entitlements` and `project.yml` — only for piece 3.

## Open questions

Things a future implementer must verify rather than assume:

1. **Does a Control Center AirPlay route actually produce a pinnable HAL device?** Not verified — the probe above ran with nothing routed. Whether the device carries `kAudioDeviceTransportTypeAirPlay`, whether Vibe can pin it explicitly rather than only follow it as the default, and whether it survives being deselected, all decide whether even piece 1 has anything to show. **Test this first; it is cheap and it may close the whole file.**
2. **Does an AirPlay bind block?** `configureOutputDeviceOnQueue:` (`AudioPlayer+Devices.m:158`) calls `setOutputUnitDevice:` synchronously on the **sole player queue**, with the engine stopped and the node detached, and there is no timeout on that HAL round trip. A network device is the first plausible way it stalls, and a stall there wedges playback.
3. **Multi-room AirPlay 2.** Does macOS expose several simultaneous targets as one aggregate device, and does that change what a "section" even means?

## Sources

- [rdar://23049205 — CoreAudio can no longer enumerate AirPlay devices](http://www.openradar.appspot.com/23049205)
- [Apple Developer Forums 17664 — AirPlay no longer enumerable in 10.11 unless selected for system](https://developer.apple.com/forums/thread/17664)
- [Apple Developer Forums 750483 — kAudioHardwarePropertyDevices does not list AirPlay sound output device](https://developer.apple.com/forums/thread/750483)
- [Apple Developer Forums 698988 — macOS program audio output to AirPlay, with EQ and volume control](https://developer.apple.com/forums/thread/698988)
- [Apple Developer Forums 744128 — ApplicationMusicPlayer on macOS doesn't work with AirPlay (AVRoutePickerView)](https://developer.apple.com/forums/thread/744128)
- [AVRoutePickerView — Apple Developer Documentation](https://developer.apple.com/documentation/avkit/avroutepickerview)
- [Tune up your AirPlay audio experience — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10238/)

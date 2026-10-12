# Not doing: AirPlay targets as output devices (macOS)

**Declined.** Vibe will not list AirPlay targets in its own output device list.

## Why

1. **AirPlay already works with no code.** Pick the target in the menu-bar Sound picker or Control Center. macOS creates its HAL device and makes it the default output. Vibe on **System Output**, the shipped default, follows the default and plays there. A device the user pinned explicitly does not follow the default, by design.
2. **Listing targets inside Vibe goes against staying light, simple and fast.** The only way to name an unrouted target is a Bonjour browse. That costs a macOS 15+ **Local Network** permission prompt and a second use of the network entitlement for the privacy policy to explain. And a listed target still cannot be connected. The best flow is "click the row in Vibe, then pick it again in the system picker".

## The platform facts

- **An unrouted AirPlay target is not in the HAL.** A probe on macOS 26.5 found 8 targets with `dns-sd -B _airplay._tcp`, and none of them in `kAudioHardwarePropertyDevices`.
- **macOS makes an AirPlay HAL device only when the system routes to a target**, from Control Center or Sound settings. `kAudioHardwarePropertyDevices` is the whole enumeration surface. There is no browse and no connect.
- **Binding needs an existing device.** `kAudioHardwarePropertyDefaultOutputDevice` and `kAudioOutputUnitProperty_CurrentDevice` both take an existing `AudioDeviceID`.

## Dead ends, so they are not explored again

- **The `"AirPlay"` pseudo-device and its `kAudioDevicePropertyDataSources`.** Removed in macOS 10.11 (rdar://23049205, [forum thread 17664](https://developer.apple.com/forums/thread/17664)). `kAudioHardwarePropertyTranslateUIDToDevice` with UID `"AirPlay"` answers `kAudioObjectUnknown` on 26.5.
- **`AVRoutePickerView`.** Its `player` is an `AVPlayer`, with no bridge to a hosted output unit. On macOS it is reported not to route reliably even for its own player ([744128](https://developer.apple.com/forums/thread/744128), [698988](https://developer.apple.com/forums/thread/698988)).
- **`AVRouting` and `AVCustomRoutingController`.** For third-party, non-AirPlay routes.
- **Bonjour discovery alone** (`NWBrowser` over `_airplay._tcp`). It names targets but cannot connect one. A row that does nothing when clicked is worse than no row.
- **A RAOP or AirPlay 2 sender inside Vibe.** AirPlay 1 depends on Apple's leaked RSA key. AirPlay 2 needs SRP pairing, Curve25519 and ChaCha20-Poly1305. Not shippable in the Mac App Store.

## If the verdict ever changes

- **Test first whether a Control Center route produces a pinnable HAL device.** Check whether it carries `kAudioDeviceTransportTypeAirPlay`, whether Vibe can pin it explicitly, and whether it survives being deselected. This is cheap and may settle the question.
- **Grouping existing AirPlay devices is the only cheap part.** `AudioDevice.transportType` is already read (`CoreAudioUtil readTransportType:forDeviceID:`), and Settings > Audio labels each row by it. But such a section would usually hold one device, the one already playing.
- **A transport read must never join the strict-sweep rule.** `enumerateOutputDevicesAcceptingPartial:` discards a device whose required reads fail and marks the sweep incomplete. A failed transport read must degrade to "unknown transport", or a driver with no transport property vanishes from the list.
- **The Output menu resizes in place** (`OutputDevicesMenuController menuNeedsUpdate:`), so an open menu refreshes without losing tracking. Its prefix arithmetic assumes one System Output item and one separator. Settings > Audio's device table (`SettingsAudioOutputViewController`) is a separate builder.
- **A network device's bind is unmeasured.** The output unit binds on its own serial queue with no timeout of Vibe's own (`Audio/Mac/Devices/AGENTS.md`). A stalled bind holds every later bind, configure and start behind it.
- **Multi-room AirPlay 2** may appear as one aggregate device. Check before designing a section.

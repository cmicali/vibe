# Not doing: AirPlay targets as output devices (macOS)

Vibe uses the output devices CoreAudio exposes. Pick an AirPlay destination in Control Center or Sound settings, then use **System Output** in Vibe. A pinned device does not follow the system default.

## Why discovery is out of scope

Bonjour discovery can name an AirPlay receiver. It does not provide an `AudioDeviceID` or connect Vibe's hosted output unit to it. `AVRoutePickerView`'s [player property](https://developer.apple.com/documentation/avkit/avroutepickerview/player) takes an `AVPlayer`. Vibe does not use that player. [AVRouting](https://developer.apple.com/documentation/avrouting) supports custom non-AirPlay routes.

A separate AirPlay sender would add another audio transport. The system route already serves this use case.

## If this is revisited

- Probe a routed AirPlay device first. Check whether it can be pinned and whether its identity survives a route change.
- `AudioDevice.transportType` already supplies the label in Settings > Audio. A failed transport read must remain optional in `enumerateOutputDevicesAcceptingPartial:`.
- The Output menu and Settings device table are separate builders. Check both.
- Device binding runs on the output unit's serial queue. Vibe cannot cancel a stalled HAL call (`Vibe/Audio/Mac/Devices/AGENTS.md`).

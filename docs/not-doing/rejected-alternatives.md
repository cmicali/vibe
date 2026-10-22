# Rejected alternatives

Alternatives to the current design and the reasons to keep them out.

## Same-path duplicate downloads: independent admission checks

`AudioFileMaterializationCoordinator` owns one path-keyed materialization claim. Playback and prefetch keep separate handle runs over that claim (`vibe-libs/files/FileLoading/AGENTS.md`).

An advisory check before starting a download leaves a race between the check and registration. Separate begin/end checks also miss a prefetch joining an existing metadata transfer. Admission and ownership must use the same claim table.

## A smaller iOS now-playing window: Picture in Picture

Picture in Picture is a video affordance. It is not a suitable way to make a compact music-player window. The mac-like strip is reached by width, not height (`Vibe/iOS/Player/AGENTS.md`).

## Chapters in M4A and M4B as rows

Revisit only if users ask for audiobooks or chaptered mixes. The shape would be the FLAC cue sheet's: AVFoundation's chapter metadata becomes window entries through `entriesForFile:`'s large-file gate (`Vibe/Playlist/AGENTS.md`).

## A wedged background handle open: widening the background lane

Every transfer slot ends at stage-1 settlement. Live handle runs have a separate limit of six per coordinator (`vibe-libs/files/FileLoading/AGENTS.md`, J8 in `docs/file-loading-spec.md`).

- **Raising `maximumBackgroundMaterializations` to 2.** It doubles concurrent background provider transfers against the foreground-priority rule. It tolerates exactly one wedge. It leaves a transfer slot carried into a handle open.
- **A watchdog that reclaims a wedged run on a deadline.** Reclaiming lets stranded workers grow without bound. A never-returning call stays one of the six until restart and holds no transfer slot, which is the bounded failure.

## The Bluetooth route glyph: asking the system what the device is

The iOS card's route indicator draws a device glyph for a Bluetooth route by matching the route's `portName` (`VibeOutputRouteSymbolName`, vibe-libs' `audio/OutputDevices/iOS/OutputRouteRules.h`). The name is user-renamable, so it is a guess. Apple says no audio API answers the question ([forum thread 815255](https://developer.apple.com/forums/thread/815255)). Every other signal was checked against the iOS 27 SDK and rejected:

- **`AVAudioSessionPortDescription`.** None of its fields identifies the model.
- **Parsing the Bluetooth `UID`.** It is the MAC address plus a suffix, an undocumented format. A manufacturer prefix could say "Apple" at most. A hardware address is a privacy liability.
- **CoreBluetooth.** It sees GATT peripherals, while A2DP audio pairs in Settings. It gives the same user-set name and costs a Bluetooth permission prompt.
- **ExternalAccessory and AccessorySetupKit.** They cover only MFi accessories the app declares, or accessories the app set up. Neither covers AirPods or Beats.
- **`CMHeadphoneMotionManager`.** Availability and motion only, with no descriptor.
- **The system picker's icon.** Reading it means walking AVKit's subviews, which is undocumented. `MPVolumeView`'s route images are deprecated.
- **`AVSystemRoute.routeSymbolName` (iOS 27).** It answers only for routes the app's own media device extensions provide.

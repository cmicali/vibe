# Rejected alternatives

Designs weighed and turned down, kept so they are not proposed again. Each entry says what shipped and why the alternative lost. Where a full plan existed, `git show <sha>:docs/done/<file>` holds it.

## Same-path duplicate downloads: a narrow compare-and-set, or nothing

Plan: `git show c4751ce4:docs/done/cloud-materialization-claim-plan.md`.

Shipped: `AudioFileMaterializationCoordinator` is a path-keyed claim that owns only making bytes local. The playback and prefetch open race lives untouched above it. Without it, a claim registered between an advisory check and the materialize was invisible, and both paths downloaded the same bytes.

- **A begin/end compare-and-set pair** consulted by playback and prefetch when they register. It covers only the metadata-second direction. A prefetch starting on top of a lane transfer is untouched. It also kept a one-second recheck poll, which the `waiter` vocabulary rules out.
- **Doing nothing.** The cost is one bounded duplicate download, and `cloud.metadata_lane_stands_aside` detects it. But the protection came from hold ordering that nothing in the code stated. A later change to that ordering would remove it silently.
- **The claim does not have to rebuild the prefetch/open race.** That race is over which open consumes the play request. A claim that owns only bytes does not touch it.

## A smaller iOS now-playing window: Picture in Picture

iPadOS 26 holds every window at least about 486 pt tall. `AVPictureInPictureController` with custom frames was proposed to get under that floor. Rejected: Picture in Picture is a video affordance and the wrong tool for a music player. The mac-like strip is reached by width, not height (`Vibe/iOS/Player/AGENTS.md`).

## Chapters in M4A and M4B as rows

Skipped. A scan of the libraries at hand found no chaptered M4A and no `.m4b`. Revisit only if audiobooks or chaptered mixes come up. The shape would be the FLAC cue sheet's: AVFoundation's chapter metadata becomes window rows through `rowsForFile:`'s large-file gate (`Vibe/Playlist/AGENTS.md`).

## A wedged background handle open: widening the background lane

Plan: `git show fabbc5da:docs/done/background-lane-wedged-open-starvation.md`. The decision is J8 in `docs/file-loading-spec.md`.

Shipped: every transfer slot ends at stage-1 settlement, and live handle runs are bounded separately (six per coordinator, `Loading/AGENTS.md`). Before, a never-returning prefetch or gapless open carried the sole background transfer slot forever.

- **Raising `maximumBackgroundMaterializations` to 2.** It doubles concurrent background provider transfers against the foreground-priority rule. It tolerates exactly one wedge. It leaves a transfer slot carried into a handle open.
- **A watchdog that reclaims a wedged run on a deadline.** Reclaiming lets stranded workers grow without bound. A never-returning call stays one of the six until restart and holds no transfer slot, which is the bounded failure.

## The metadata-loader test hold race: three fixes not taken

Plan: `git show 557c191f:docs/done/fix-metadata-loader-test-hold-race.md`.

The fake provider operation in `Tests/AudioTrackMetadataLoaderTests.m` read `blocksUntilCancelled` one step after the point the test synchronized on, so it could complete as a success. Shipped: the read is hoisted, and a gate at the bad interleaving is the regression.

- **A longer settle delay.** The bug is a first start taking the wrong branch, which has already happened by then. Slower, no more correct.
- **Making every hold/clear pair observable** with a second expectation. It edits all ten pairs for the same guarantee.
- **One lock around the fake's vulnerable steps.** It works only if released before the completion step, and gives no stronger guarantee than the hoisted read.

## The Bluetooth route glyph: asking the system what the device is

The iOS card's route indicator draws a device glyph for a Bluetooth route by matching the route's `portName` (`VibeOutputRouteSymbolName`, `Audio/iOS/OutputRouteRules.h`). The name is user-renamable, so it is a guess. Apple says no audio API answers the question ([forum thread 815255](https://developer.apple.com/forums/thread/815255)). Every other signal was checked against the iOS 27 SDK and rejected:

- **`AVAudioSessionPortDescription`.** None of its fields identifies the model.
- **Parsing the Bluetooth `UID`.** It is the MAC address plus a suffix, an undocumented format. A manufacturer prefix could say "Apple" at most. A hardware address is a privacy liability.
- **CoreBluetooth.** It sees GATT peripherals, while A2DP audio pairs in Settings. It gives the same user-set name and costs a Bluetooth permission prompt.
- **ExternalAccessory and AccessorySetupKit.** They cover only MFi accessories the app declares, or accessories the app set up. Neither covers AirPods or Beats.
- **`CMHeadphoneMotionManager`.** Availability and motion only, with no descriptor.
- **The system picker's icon.** Reading it means walking AVKit's subviews, which is undocumented. `MPVolumeView`'s route images are deprecated.
- **`AVSystemRoute.routeSymbolName` (iOS 27).** It answers only for routes the app's own media device extensions provide.

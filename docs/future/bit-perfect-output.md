# Bit-perfect output for external DACs (macOS)

Written 2026-09-14; **implemented 2026-09-15 on the `worktree-bit-perfect-output` branch.**
The file:line anchors below are against `main` at `feb816a`, the tree the plan was written
against, and are kept as the record of what was there; the code as landed is described by
`Vibe/Audio/Mac/Devices/CLAUDE.md`. What follows first is what the spike and the build
answered, then the plan as it was executed.

**Follow-up:** Exclusive output is now a separate switch below Bit-perfect output, off by default. `VIBE_ENABLE_EXCLUSIVE_OUTPUT=0` removes only exclusive device access and its control; rate/depth matching and graph pruning remain. The original plan below predates this split.

## The answers (2026-09-15, this Mac, macOS 27.0, Xcode 26 SDK)

- **Q1, the write and the wait.** One `kAudioStreamPropertyPhysicalFormat` write moves the
  device; the built-in speakers and BlackHole read the new nominal rate back within the first
  5 ms poll. The 1.5 s deadline stands.
- **Q2, transparency.** With the mode on, 44.1/16, 48/16, 88.2/24 and 96/24 WAVs and a 96/24
  FLAC arrive at BlackHole **sample-exact** — 265,924 to 766,590 frames compared per file,
  zero mismatches — once the master bus is reconnected at the device's rate (Q6).
- **Q3, hog from the sandbox.** Works: the sandboxed debug build takes the speakers
  (`pid` = Vibe's), releases them 6 s after a pause, retakes them on resume, and the kernel
  drops the hog at quit. **The two-build contingency is not needed.**
- **Q4, the format write from the sandbox.** Works, no entitlement.
- **Q5, FLAC's depth.** CoreAudio spells it with the ALAC flags — `flac (0x00000003) from
  24-bit source` — so the rule's decoder reads both formats one way.
- **Q6, the engine's connection rates.** `mainMixerNode → outputNode` is connected at the
  mixer's default **44.1 kHz whatever the device**, and the output unit resamples the
  difference — 1.4e-3 against a 48 kHz device, and the reason the first loopback was not
  exact. The switch therefore reconnects the master bus at the device's rate with the engine
  stopped (`reconnectMasterBusOnQueueAtRate:`), tap removed and reconciled back. No late
  self-stop was observed after the restart.
- **Q7, a real DAC.** Not attached; the integer-depth half of the rule is unit-tested only.
- **The everyday chain (Phase 5), mode off.** With BlackHole set to the file's rate by hand:
  a 44.1 kHz file through the normal chain — mixer at 44.1, varispeed at pitch 0 — differs
  from the file by up to **5.4e-6**, last-bit float differences from the varispeed alone; a
  48 kHz file differs by 1.4e-3 from the output unit's resampling. So the normal chain is not
  bit-exact, for two separable reasons, and Phase 5 is a change, not a measurement.
- **Two rules moved while building.** Eligibility is decided by transport alone: the System
  Output *policy* is refused as the absence of a chosen device, but the device that happens
  to be the current default is judged like any other (the built-in speakers were wrongly
  grayed out under the first draft). And a vanished device is abandoned by the *player*
  (`abandonBitPerfectForVanishedDeviceOnQueue`), the shell reading the report's `enabled`
  flag on the `-1` announcement — the launch-time `-1`, made while the saved device is still
  binding, must not turn the mode off, and the shell alone cannot tell the two apart.
- **One accessor bug the loopback did not see.** The first `setHogOwnedByThisProcess:NO`
  refused to write while the holder was us, so the hog was never released before quit; the
  standalone HAL tests (a plain process, and one with a stopped `AVAudioEngine` bound)
  isolated it to the app's own logic.

---

This plan is written to be executed phase by phase by an implementation agent. Phase 0 is a
one-day spike whose measurements settle the one shape this document deliberately leaves open
(how the rate-switch wait is written) and the one scope risk (hog mode from the sandbox);
every later phase compiles, passes
`make test`, and is verifiable on its own. Read the root `CLAUDE.md` (the complexity budget and
the vocabulary table), `Vibe/Audio/CLAUDE.md` (the play settlement, the fades, the engine idle
stop), `Vibe/Audio/Mac/Devices/CLAUDE.md` (the HAL layer this lands in), `Vibe/Common/CLAUDE.md`
and `Vibe/Mac/Settings/CLAUDE.md` (the store-first settings contract) and `Tests/CLAUDE.md`
first; verification needs the `vibe-debug` and `vibe-stress` skills.

## The feature

One switch, **Settings > General > Audio > Bit-perfect output**, off by default, macOS only.
While it is on and the user has chosen an output device explicitly, Vibe delivers each file's
decoded samples to that device unchanged. Concretely, "bit-perfect" here means all five of:

| # | Condition | How Vibe makes it true |
| --- | --- | --- |
| 1 | **No sample-rate conversion anywhere** — not in the mixer, not in the output unit, not in `coreaudiod` | Before a track starts, the device's nominal sample rate is set to the file's rate, when the device offers it |
| 2 | **The bits go to the DAC as they are** | The output stream's physical format is set to the integer depth that *equals* the source's — a 16-bit file goes out as `i16` even on a DAC that offers `i32`, and the DAC does what it does — else the smallest integer depth above it, else float32, which is exact for every source up to 24 bits |
| 3 | **Every gain stage at unity** | FX completely off — the controls withdrawn and every effect cleared the moment the mode goes on, and no FX segment built at the next launch — node volume 1.0 once the declick fade-in lands, mixer at unity, and the device's *software* volume at 100 %, which Vibe cannot set and therefore reports |
| 4 | **No other client mixed in** | Exclusive ("hog") access to the device while the engine runs; released when the engine idles, so system sounds and other apps get the DAC back the moment Vibe is quiet |
| 5 | **Nothing else that can change the bits is in the chain** | Under the mode each track connects player node → main mixer directly — no varispeed is minted, so there is no resampler to be transparent — the pitch resets to 0 and the fader goes away; the crossfade is held at the declick minimum, so two tracks are never summed; the gapless splice (consecutive segments on one node, bit-exact by construction) stays |
| 6 | **The device is left as it was found** | The first change Vibe makes to a device's format in a run is remembered; turning the mode off, choosing another device, or quitting writes it back |

What the user sees: a closed lock riding the codec line in the header, beside the file's own
"FLAC | 96.0 kHz", whenever the current track is being delivered bit-perfect, and an **open
lock with a hover tooltip naming the one reason** whenever the mode is on and it is not ("The
device does not offer 44.1 kHz; playing at 88.2 kHz", "This file is lossy; the decoded audio is
delivered unchanged"); the Settings row's caption saying the same; and `dump_state` carrying
every input to that decision.

**Inherent exceptions, stated once so nobody chases them.** The 10 ms declick fade-in at every
start and fade-out at every stop are not unity, by design; a track boundary that changes the
sample rate is a hard cut after the outgoing declick, followed by whatever relock time the DAC
needs; and a lossy file is decoded first, then delivered unchanged — the mode makes no claim
about the decoder.

**Two words, used strictly.** *The mode* is the switch: while it is on, the chain is pruned to
the exact one — no FX, no varispeed, no crossfade, no pitch fader. *Active* is the report: the
chosen device has been switched, hogged and found at unity, and the source is lossless. **The
mode can only be on with an eligible device** — explicitly chosen, and on a transport that can
carry the bits unchanged: the switch is disabled with a note on System Output or an ineligible
device, the Output menu grays System Output and every ineligible device out while the mode is
on, and the fallback that lands on System Output when a device vanishes turns the mode off. So
"mode on" always implies a device the mode can drive, and there is no half-on state to explain.

**The everyday chain must be transparent too.** Outside the mode, with the FX graph present
but every effect off and the pitch at 0, the bits must reach the device unchanged. That is a
requirement on the normal chain, measured with the same loopback and fixed in Phase 5 if it
does not hold today — the parked 20 Hz EQ bands and a varispeed at ratio 1.0 are the two
suspects.

## What was verified on this machine before planning

Probed read-only on 2026-09-14 with the program in Appendix A (`clang -framework CoreAudio`,
no app involved). Every output device on this Mac:

| Device | Transport | Nominal | Available rates | Physical | Hog settable | Software volume |
| --- | --- | --- | --- | --- | --- | --- |
| Chris's AirPods Pro | `blue` | 48000 | 24000, 48000 | 2ch float32 | yes | 0.562, **no hardware volume** |
| BlackHole 2ch | `virt` | 48000 | 8000 … 768000 (13) | 2ch float32 | yes | 0.438 |
| MacBook Pro Speakers | `bltn` | 48000 | 44100, 48000, 88200, 96000 | 2ch float32 | yes | 0.437 |
| ZoomAudioDevice | `virt` | 48000 | 44100 … 192000 (6) | 2ch float32 | yes | 1.000 |

Four things follow, and they shape the plan:

- **No device here exposes an integer physical format.** Apple's built-ins, Bluetooth and the
  virtual drivers are float32 at every rate; integer formats (`i16`/`i24`/`i32`) appear on USB
  Audio Class DACs, none of which was attached at planning time. So the rate, exclusive-access
  and software-volume halves are testable now, on the built-in speakers and on BlackHole, and
  the depth-selection half is testable only once a real DAC is plugged in (Phase 4 has the
  checklist for that day).
- **Every device carries a software "virtual main volume" below 1.0 right now**, and the
  AirPods have *only* that — the HAL scales samples in software for them. This is a real
  bit-perfect breaker that no rate or hog setting touches, which is why the report reads it
  and says so rather than pretending. (A second probe run forty minutes later found the
  AirPods at 24 kHz and 0.062 — the headset profile had taken over. A Bluetooth device
  re-negotiates its own rate and volume with nobody asking, which is one more reason the
  rules read what the device offers *at play time* and never remember it.)
- **Hog mode is settable everywhere**, and nobody holds it (`pid=-1`).
- **BlackHole is the loopback oracle.** It accepts every rate, is float32 (so the float path
  is exact end to end), and is a `virt` transport — which the hog rule below never hogs, and
  that is exactly what lets a second process record what Vibe sends it and compare it
  sample-for-sample against the file.

The SDK facts these rest on, checked against the macOS 26 SDK:

- `kAudioDevicePropertyHogMode` (`'oink'`, `CoreAudio/AudioHardware.h:932-942`): a `pid_t`, -1
  when free. **TRAP: setting it ignores the value passed in and *toggles*** — "If the current
  process owns exclusive access, it is released … If no process has exclusive access, this
  process gains ownership." A second acquire is a release. Both accessors below read first.
- `kAudioDevicePropertyNominalSampleRate` / `kAudioDevicePropertyAvailableNominalSampleRates`
  (device, global scope; a set is applied asynchronously and must be read back).
- `kAudioDevicePropertyStreams` (output scope) → `kAudioStreamPropertyPhysicalFormat` (an
  `AudioStreamBasicDescription`, rate and depth together) and
  `kAudioStreamPropertyAvailablePhysicalFormats` (`AudioStreamRangedDescription[]`).
- `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (`'vmvc'`,
  `AudioToolbox/AudioHardwareService.h:70`) is **not deprecated** — only the older "Master"
  spelling beside it is — and reads through plain `AudioObjectGetPropertyData` in the output
  scope, which is what the probe did. The `AudioHardwareService*` *functions* are deprecated;
  none is needed.
- `kAudioDevicePropertyTransportType` — `'virt'` for BlackHole and Zoom, `'blue'`, `'bltn'`.
  The AirPlay investigation (`docs/not-doing/airplay-output-devices.md`, piece 1) already
  designed `readTransportType:forDeviceID:`; this plan lands it.
- A lossless file's bit depth: `AVAudioFile.fileFormat.streamDescription` carries
  `mBitsPerChannel` for PCM, and for ALAC the source depth rides `mFormatFlags` as
  `kAppleLosslessFormatFlag_{16,20,24,32}BitSourceData` = 1…4
  (`CoreAudioTypes/CoreAudioBaseTypes.h:544-547`). Whether CoreAudio's FLAC ASBD uses the same
  flag convention is **spike Q5**; `kAudioFormatFLAC` (`:431`) documents nothing about it.
- The float path is exact by arithmetic, not by hope: a 16- or 24-bit integer sample divided
  by 2^15 or 2^23 is representable in float32 (24-bit significand), a unity mix adds exact
  zeros, and multiplying back by 2^23 or 2^31 for an `i24`/`i32` stream yields the original
  integer. Only a 32-bit source (integer or float) cannot round-trip a float32 graph, and the
  report says so instead of claiming otherwise.

## What exists today (anchors verified at `feb816a`)

**The engine never touches the device's rate, depth or ownership.** `grep -rn` for
`NominalSampleRate`, `HogMode`, `PhysicalFormat` and `VirtualMainVolume` under `Vibe/` finds
nothing. The mixer runs at whatever rate the device happens to have, and every file at another
rate is resampled by `mainMixerNode`.

**The graph.** Each track is `AVAudioPlayerNode → AVAudioUnitVarispeed → mainMixerNode`,
connected once per track at the file's own format
(`Vibe/Audio/AudioPlayer+Graph.m:52`, `attachConnectedNodeForFormat:`; the rate is
`1.0 + pitch/100` at `:36`). With FX off the master bus is `mainMixerNode → outputNode`
(`AudioPlayer.m:309`, `installMasterBusOnQueue`); with FX on it is `AudioFX.installInEngine:`
(`AudioFX.m:188`), whose two low-kill EQ bands "stay live for the engine's lifetime, never
bypassed … parked inaudibly at 20 Hz" (`:191`, `band.bypass = NO` at `:203`). **A parked 20 Hz
high-pass is not a pass-through**, so the FX segment and bit-perfect cannot coexist in one
run — and the segment is a launch-time choice (`enableFX:`, `MainPlayerController.m:142`).
`--silent` zeroes `mainMixerNode.outputVolume` (`AudioPlayer.m:297`; the trap at
`Audio/Levels/CLAUDE.md:37`) — debug only, and the loopback runs below must launch without it.

**The varispeed and the pitch fader.** `retireOutgoingChainOnQueueWithDeclick:` mints one
varispeed per track (`AudioPlayer.m:627-629`) and `connectNode:throughVarispeedWithFormat:`
(`+Graph.m:21`) wires through it; `retireNode:varispeed:` and `detachRetiredFadePair:` already
accept a nil varispeed. The fader writes `audioPlayer.pitch` at `MainPlayerController.m:1162`
and mirrors it back at `:1136`; `playbackRate` (`:530`) derives every time label, skip and
the UI tick rate from it, so a pitch of 0 needs no second branch anywhere. The panel is
`MainWindow.setPitchPanelShown:animate:` (`MainWindow.m:315`), reached from View > Show Pitch
Control — validated in the ViewToggle domain at `+Menus.m:27`, which always answers YES today —
and from the bare P key (`TransportKeyMonitor.m:251`).

**The Output menu** (`OutputDevicesMenuController.m:59`, `menuNeedsUpdate:`) sets every
item's `enabled = YES` explicitly (`:90` System Output, `:105` each device), so graying is one
condition per line; the same controller builds the Settings > General popup. `AudioDevice`
carries `name`/`uid`/`deviceId`/`isSystemDefault` and no transport (`AudioDevice.h:20-25`); the
sweep's strictness rule (`AudioDeviceManager.m:391`) is why a transport read must be an
*optional refinement that never discards a device* — the AirPlay investigation's TRAP.

**The engine idle stop** waits `kEngineIdleStopDelaySeconds` = 6 (`AudioPlayer+Engine.m:12`)
before releasing the device.

**Both release paths are sandboxed**: `ENABLE_APP_SANDBOX: YES` is set for the whole `Vibe`
target (`project.yml:347`), and `release.sh` re-signs the same product with Developer ID
(`:343-344`). There is no unsandboxed build today.

**The crossfade** is pushed by the Crossfade effect (`+Settings.m:50-52`) into
`AudioPlayer.setCrossfadeMilliseconds:` (`AudioPlayer.m:1356`), which on every write re-arms or
unqueues the gapless splice — the hook a forced minimum rides for free.

**The play settlement** is `finishPlayOnQueueWithFile:error:openRequestId:`
(`AudioPlayer.m:713`): `consumeRequest:` at `:714` is the supersession guard, the node is
attached and connected at `:739`, parked at volume 0 at `:753`, and the engine started through
`startEngineAndPlayNode:` at `:766`. A prefetched next track reaches the same method in the
**same queue turn** as its submission (`consumePrefetchedFileOnQueueForPath:`, `:655`), while
the outgoing node has only just begun its fade — which is why a rate switch cannot simply stop
the engine there (see *the park* below).

**Where audio stops and starts.** `startEngineAndPlayNode:` (`AudioPlayer+Engine.m:20`) is
the single funnel for starting playback; `[_engine startAndReturnError:]` is `:28`. The
deferred idle stop (`scheduleEngineIdleStopOnQueue`, `:52`) stops the engine at `:66`
(Stopped) and `:83` (Paused), and is what "releases the output device" today. The only other
engine stop is the device switch's, `AudioPlayer+Devices.m:181`.

**The fades.** `retireNode:varispeed:milliseconds:` (`AudioPlayer+Fades.m:172`) fades an
audible outgoing node and counts it in `_activeRetiredOutputCount`
(`AudioPlayerInternal.h:202`); `completeRetiredFadePair:` (`+Fades.m:117`) decrements at
`:125` when the pair is silent and detached. `preemptRetiredFadesOnQueue` (`:153`) cuts a
crossfade-length fade down to the declick minimum. Together they are the "outgoing audio is
silent" event the rate switch has to wait for.

**Device switching.** `configureOutputDeviceOnQueue:` (`AudioPlayer+Devices.m:158`) stops
the node and the engine (`:181`), rebinds the output unit (`:191`, `setOutputUnitDevice:` at
`:132`, which is `kAudioOutputUnitProperty_CurrentDevice` at `:146`), then restores the live
track at its position (`:198`). `handleEngineConfigurationChange` (`:274`) is the recovery for
the engine stopping itself on a device or format change — the notification our own rate
switch will also provoke. `setOutputDeviceOnQueue:` (`:371`) is the checked mutation and
`setOutputDevice:` (`:455`) the public entry. `activeOutputDeviceID` (`:119`) answers the
bound device. `currentlyActiveAudioDeviceId` is the debug read `dump_state` uses
(`Debug/Mac/DebugStateDump.m:46`).

**Raw HAL reads** live in `CoreAudioUtil` (`CoreAudioUtil.h:25-30`): one property per method,
each returning success separately from its answer. The sweep in `AudioDeviceManager`
(`enumerateOutputDevicesAcceptingPartial:`, `:391`; `readDeviceForID:` at `:52`) is
**untouched by this plan** — the mode reads capabilities of the one bound device at play
time, never per device per sweep, so the strict-sweep rule gains no new load-bearing read.

**Settings.** `audioFXEnabled` is the model for a mac-only BOOL: key at
`AppSettings+Mac.m:34`, registered default at `:100`, accessor at `:623`, declaration with its
contract at `AppSettings+Mac.h:260`. The device choice is `audioOutputDeviceUID` (`:83`). A
writer requests a `VibeSettingsLiveEffect` (`MainPlayerController+Settings.h:10-63`; the last
bit is `ReopenLastPlaylist = 1UL << 20` at `:50`) and `applySettingsLiveEffects:` maps it
(`+Settings.m`; the crossfade push at `:50` and the FX-controls effect at `:116` are the two
shapes this feature copies). The Output popup is the first row of Settings > General's Audio
section (`SettingsGeneralViewController.m:84`), refreshed by `refreshFromSettings` (`:103`).
The FX switch is `SettingsPlaybackViewController.m:80` (its restart caption), `:111` (state),
`:138` (toggle).

**Whether FX exist for the user is decided in four places today**, each reading
`audioFXEnabled` beside `audioPlayer.fx != nil`: the launch-time `enableFX:`
(`MainPlayerController.m:142`), the FX menu's visibility and its children's key equivalents
(`MainMenuBuilder.m:417`), FX menu validation (`MainPlayerController+Menus.m:38`) and the key
monitor (`TransportKeyMonitor.m:290`); the `FXControls` effect (`+Settings.m:117`) clears the
five effects when the setting reads off. The debug channel's model-level FX verbs deliberately
bypass the setting (`DebugCommandTable.m:183`) and keep doing so.

**The header's codec line** composes FX symbols from `VibeFXDisplayState`
(`TrackDisplayController.h:34-40`) in `fxSymbolNames` (`TrackDisplayController.m:168`),
re-rendered by `renderFXState:` (`:437`) into `composeFileMetadataLabel` (`:465`); the
controller feeds it from `updateFXIndicators` (`MainPlayerController+Transport.m:168`).
Per `Mac/MainWindow/APPEARANCE.md`, "the FX symbols are deck state, not file info, and keep
composing" — the lock is the same kind of thing.

**Test audio** is all 44.1 kHz / 16-bit (`generate-test-audio.sh:49,51`). Phase 0 adds the
rates and depths the mode exists for.

## Decisions taken during planning

| | |
| --- | --- |
| Scope | **An eligible device only: explicitly chosen, on a transport that can be bit-perfect.** One rule, `VibeBitPerfectDeviceEligible(isSystemDefault, transportType)`, read in three places: the Settings switch is *disabled* on an ineligible device with a caption saying why ("Choose a wired output device in the Output menu to enable bit-perfect output"); the Output menu and the Settings popup gray out System Output and every ineligible device while the mode is on; and the device-vanished fallback (`+Devices.m:49`, which persists System Output) also turns the mode off through `didChangeOutputDevice:`. System Output is a policy that follows whatever macOS points at, and hogging or reconfiguring *that* silences alerts and every other app through a device the user never named. **Eligibility is an allowlist, not a blocklist**, of the SDK's eighteen transport types (`AudioHardware.h`, `kAudioDeviceTransportType*`): built-in, PCI, USB, FireWire, Thunderbolt, HDMI, DisplayPort, AVB (uncompressed, clocked Ethernet audio) and virtual (nothing behind it, and the loopback that verifies this feature). Everything else is out — Bluetooth and Bluetooth LE (compressed), AirPlay (compressed, remote), Continuity Capture wired and wireless and the two Remote types (streamed to another device), aggregate and auto-aggregate (the HAL drift-corrects members against a master clock, which resamples), and Unknown, which includes a device whose transport read failed. A new transport Apple adds is ineligible until someone argues it in, which is the safe direction. |
| Rate rule | Exact rate when the device offers it; else the **smallest integer multiple** the device offers (44.1 → 88.2 → 176.4; 48 → 96 → 192), which keeps the one conversion left at an integral ratio; else the device is left alone and the report reads *rate unsupported*. No guessing at a "nearest" rate. |
| Depth rule | **As-is.** At the chosen rate, the integer format whose depth equals the source's; else the smallest integer depth above it; else float32 (Apple's built-ins and the virtual devices offer nothing else, and it is exact to 24 bits). A 16-bit file therefore goes out as `i16` on a DAC that also offers `i32`, and the DAC's own handling is the DAC's business. A lossy source has no native depth — the decoder hands over float — and takes 24. A 32-bit source on a stream that tops out at 24 reports *depth insufficient* and plays anyway. |
| One write | The chosen format is written once, as the output stream's `kAudioStreamPropertyPhysicalFormat`, which carries rate and depth together; a device whose stream lists no physical formats gets the device-level nominal-rate write instead. Spike Q1 confirms the stream write moves the nominal rate on the built-in speakers. |
| The wait | After the write, the player queue **polls the nominal rate synchronously, bounded** (deadline from Q1, capped at 1.5 s), then proceeds either way — a deadline miss plays the track and reports *switch failed*. Synchronous is the boring shape: the engine is already stopped, nothing is audible (the park guarantees it), the UI getters are lock-only, and `configureOutputDeviceOnQueue:` already blocks this queue on "a potentially slow HAL rebind". The async listener-and-continuation shape is written down under Phase 2 and adopted only if Q7 measures a real DAC taking seconds. |
| The park | A settlement that needs a switch while outgoing audio is still counted (`_activeRetiredOutputCount > 0`) preempts the fades to the declick length and **parks itself** until `completeRetiredFadePair:` counts down to zero, then re-enters `finishPlayOnQueueWithFile:…` verbatim. Re-entry lands on `consumeRequest:`, so a newer play or a stop in the meantime drops it for free — **no new generation counter**, and Loading semantics (play/pause toggling the pending intent) stay intact because the request is not consumed until the re-entry. |
| Hog rides the engine | Acquired in `startEngineAndPlayNode:` immediately before `startAndReturnError:`; released after both idle-stop `[_engine stop]`s, before the rebind in `configureOutputDeviceOnQueue:`, when the mode is turned off, and in `dealloc`. Never for a `'virt'` transport — a virtual device has no DAC behind it, and hogging one breaks the loopback that verifies this feature. While hogged, other apps and system sounds cannot use the device; the idle stop hands it back. **The idle delay becomes two numbers:** 6 s while the device is hogged, so a pause frees the DAC promptly, and 10 s otherwise, up from today's 6 — `scheduleEngineIdleStopOnQueue` picks by `_hoggedDeviceID`. The Settings caption says the hog in one sentence. |
| Format rides the settlement | `prepareOutputOnQueueForFile:` runs in `finishPlayOnQueueWithFile:` after `consumeRequest:` and before `attachConnectedNodeForFormat:`, and in `configureOutputDeviceOnQueue:`'s restore branch. Nowhere else: the gapless splice is same-rate by its own gate (`VibeGaplessFormatsMatch`, `+Gapless.m:51,106`), so a promote never needs it. |
| Restore | **The device is put back as it was found.** One slot, not a table: the first time a run changes a device's format, `prepareOutputOnQueueForFile:` remembers the device and the physical format it read *before* writing. Three edges write it back and clear the slot — the mode turned off, a switch to another device (before the rebind), and quit, through a new `AudioPlayer.prepareForTermination` that `applicationWillTerminate:` (`AppDelegate.m:313`) calls and that runs the restore synchronously on the queue via `runSyncOnQueue:`. A device that vanished cannot be written and the slot simply clears; the format it comes back with is the driver's business. Nothing restores while Vibe idles or pauses — a paused Vibe still owns its DAC's format, and only the three edges above mean "done with it". The slot holds what the device had before *Vibe's* first change: a rate the user set in Audio MIDI Setup mid-run is overwritten at quit, which is the documented cost of one slot over a listener. Hog needs no restore: it is process-bound and the kernel drops it at exit, though `prepareForTermination` releases it after the format write anyway. |
| FX | **FX are completely off while the mode is on.** One derived read, `AppSettings.audioFXAllowed` = `audioFXEnabled && !bitPerfectOutput`, replaces `audioFXEnabled` at every gate that decides whether FX exist for the user: the launch-time `enableFX:`, the FX menu's visibility and key equivalents, menu validation, and the key monitor. Turning the mode on therefore clears every active effect, hides the FX menu and kills Q/W/E/R/T immediately — the same path the FX switch's own off already takes — and disables the Playback pane's FX switch; the next launch builds no FX segment at all. A run that already has the graph reports *FX graph present* and **the mode is inert in it** — no rate switch, no hog — until relaunch: its two EQ bands are never bypassed (`AudioFX.m:191`), so an idle graph is still not a pass-through, and switching the device for it would be theater. The row reuses `STR_SETTINGS_ENABLE_FX_RESTART` verbatim. Turning the mode off restores the controls when the run has a graph and `audioFXEnabled` is on. |
| The varispeed is out | Under the mode no varispeed is minted (`AudioPlayer.m:627-629` gains the branch) and `connectNode:throughVarispeedWithFormat:` connects the node to the mixer directly when there is none. Not measured and kept, *removed*: a resampler at ratio 1.0 is still a resampler, and the plan does not rest on its arithmetic. The live effect sets the pitch to 0 (the fader follows through the existing mirror at `MainPlayerController.m:1136`) and hides the panel; View > Show Pitch Control validates NO and the P key does nothing while the mode is on. Off brings the fader back at 0. |
| The crossfade is out | A derived read, `AppSettings.effectiveCrossfadeMilliseconds` = `bitPerfectOutput ? kFadeDurationMilliseconds : crossfadeMilliseconds`, replaces `crossfadeMilliseconds` at the one push site (`+Settings.m:51`), and the mode toggle requests the Crossfade effect too, so `setCrossfadeMilliseconds:` re-arms or unqueues the splice exactly as a popup change does. The Playback pane's crossfade popup is disabled while the mode is on, with the same caption as the FX switch. The gapless splice stays: consecutive segments on one node are the file's bytes back to back. |
| Toggling it mid-track | **Both directions** reuse `configureOutputDeviceOnQueue:` onto the *current* device — a device switch onto itself — which is the existing stop-rebind-restore-at-position path and therefore the existing click-on-user-action the device menu already has. It is what rebuilds the current track's chain without a varispeed (on) or with a fresh one (off); off additionally restores the format and releases the hog first, and on System Output either direction only republishes the report. In a run with the FX graph, on only publishes the report (inert, above). |
| The report | One value type, `VibeBitPerfectReport` (status, rate, bits, float?, exclusive?, software volume), computed on the queue and published under `_stateLock` like `outputAudioActive`; a main-thread getter and **no new delegate method** — the three edges that can change it (`didStartPlaying:`, `didChangeOutputDevice:`, the live effect) already re-render the header. **The glyph has two states**: `lock.fill` when Active, `lock.open` for every other status while the mode is on, and the codec label's `toolTip` carries the status's sentence, so a hover explains an open lock — an unsupported rate playing at a multiple, a lossy source, a scaled volume. Mode off draws nothing. |
| Sandbox contingency | If Phase 0's Q3 finds hog mode or the format write refused under the sandbox, the feature ships in **two builds**: the Developer ID download built with `ENABLE_APP_SANDBOX: NO` and `VIBE_BIT_PERFECT=1`, and the App Store build sandboxed with the feature compiled out. The flag guards `.m` entry points only — the pane row's construction, the player's prepare and acquire early-outs, the launch `enableFX:` read, the menu graying — never a header, so the App Store binary is the same code with `bitPerfectOutput` reading NO everywhere. That is a `project.yml` config (or `release.sh` settings) change argued on its own when the day comes; nothing in Phases 1–5 depends on it. |
| Strings | English only until release. The wording will move while the feature is tuned, and the thirty-language pass is the release's job; `make check-translations` is the gate that makes forgetting impossible. |
| Where the code lives | `CoreAudioUtil` gains the raw accessors; `AudioPlayer+Devices.m` gains prepare, acquire, release, restore, the termination hook and the report; `+Graph.m` and the retire path gain the no-varispeed branch; `AudioDevice` gains `transportType`, read by the sweep as an optional refinement; the decisions go in **one new header, `Vibe/Audio/Mac/Devices/OutputFormatRules.h`**, argued below; the shell's gates (FX, pitch panel, crossfade, Output menu, the switch) each gain one condition; nothing new anywhere else. |
| iOS | Out of scope. See the end. |

**The one new file, argued on the feature's terms.** The rate rule, the depth rule, the
source-depth decode, the status fold and the "does this need a switch" predicate are five pure
decisions over an `AudioStreamRangedDescription` list and a source ASBD. They are exactly what
`Tests/CLAUDE.md` says to extract when "the engine is the whole class": a host-less test can
build the format lists of every device in the table above by hand and pin every branch, and
the shipping category then *calls* the rule instead of restating it. No existing `*Rules.h`
owns output formats — `GaplessSpliceMath.h` compares two files, not a file to a device — and
putting five decisions inline in `+Devices.m` would leave the only meaningful logic of this
feature untested. Two types ride in it, an enum and a struct, both plain C. If the reviewer
wants zero new files, the fallback is appending them to `GaplessSpliceMath.h` and its test,
at the cost of that header's name lying about its contents.

## Phase 0 — the spike (one day; decides the wait's shape and the sandbox question)

Build the throwaway version of Phase 1's accessors and enough of Phase 2 to switch the rate on
play with the varispeed left out, launched **`VIBE_AUDIBLE=1`** (real hardware, mixer at
unity — `--silent` would fail every comparison below by construction, and `--no-audio-hw` has
no device). Answer seven questions and write the answers into the top of this file. Nothing
else from this phase is kept.

**Test files first.** Extend `generate-test-audio.sh` with a `rates/` set derived from the
existing tone WAV with `afconvert` — `-d LEI16@48000`, `-d LEI24@96000`, `-d LEI24@88200`,
`-d LEI16@44100` (identity), and a 96 kHz / 24-bit FLAC (`-f flac -d flac` from the 96/24
WAV). Deterministic content, known rates and depths, gitignored like the rest.

**Q1. Does one stream physical-format write move the device, and how long does it take?**
On the built-in speakers (44.1/48/88.2/96 available) and BlackHole, with the engine stopped:
write `kAudioStreamPropertyPhysicalFormat` {96000, float32, 2ch}, poll
`kAudioDevicePropertyNominalSampleRate` every 1 ms, log the time to read-back. Then the same
through `kAudioDevicePropertyNominalSampleRate` alone, and then the restore — write the format
read before the first change back, and confirm the device reads it. Record whether the stream
write alone suffices (expected) and the worst read-back time seen, which sets the Phase 2
deadline.

**Q2. Is the graph transparent?** The loopback oracle, `verify-bit-perfect.swift` in the
`vibe-debug` skill's `scripts/` (kept; it is Phase 4's tool): bind an `AVAudioEngine` input
node to BlackHole 2ch via `kAudioOutputUnitProperty_CurrentDevice`, record float32 for N
seconds into a temp `AVAudioFile`, read the reference file with `AVAudioFile`, find the first
sample-exact alignment of the reference inside the capture, then report capture rate, matched
frames, mismatched frames after the alignment point and the maximum absolute error. **It
refuses to run while BlackHole's software volume reads below 1.0** — set it to 100 % in Audio
MIDI Setup first. With Vibe on BlackHole, mode on, play each `rates/` file and expect zero
mismatches from the end of the 10 ms fade-in to the end of the file, at the file's own rate.
Then set BlackHole back to 44 % once, deliberately, and play one file again: the comparison
must fail. That is both the software-volume rule proving itself and the check that the oracle
can fail at all.

Then **the everyday chain**, same oracle, mode off: BlackHole set to the file's rate by hand
in Audio MIDI Setup, a run launched with FX on and every effect off, pitch 0, the 44.1/16 file.
Sample-exact means the normal chain already delivers unchanged bits and Phase 5 is a
measurement to keep, not a change. Any mismatch is split two ways in the same session — the
same run with FX off (varispeed alone), and the FX run again with the pitch fader nudged and
returned to 0 (a varispeed that has changed rate once) — so Phase 5 knows which of the two
suspects it is fixing.

**Q3. Does hog mode work from the sandboxed debug build?** The debug build carries the same
two entitlements as release (`Vibe/Mac/App/Vibe.entitlements`). On the built-in speakers,
mode on, play: `dump_state` (Phase 2's fields, or a log line in the spike) shows
`outputHogged: true` and Appendix A's probe run from a shell shows `pid=<Vibe's pid>`; a
`say hello` from Terminal is silent while playing and audible ~6 s after pause. Then quit Vibe
mid-play and confirm the probe reads `pid=-1`. A failure here with any `kAudioHardware*Error`
does not shrink the feature: it triggers the *Sandbox contingency* row — two builds, the
Developer ID download unsandboxed with the feature in, the App Store build with it compiled
out — and the first thing to do then is repeat this question with `ENABLE_APP_SANDBOX: NO` to
confirm the sandbox was the cause.

**Q4. Does the physical-format write need anything the sandbox lacks?** Same run as Q1 but
from the sandboxed debug build rather than the unsandboxed probe. Expected: no.

**Q5. How does CoreAudio spell a FLAC's bit depth?** Read `AVAudioFile.fileFormat` of the
96/24 FLAC and of `tone.flac`: `streamDescription->mFormatID`, `mFormatFlags`,
`mBitsPerChannel`. Expected: `'flac'`, flags 3 (`kAppleLosslessFormatFlag_24BitSourceData`),
bits 0. If the flags are 0, the depth has to come from `AVAudioFile.fileFormat.settings`
(`AVLinearPCMBitDepthKey`) and the rule's decoder gains a second branch; if neither carries it,
lossless-compressed sources are treated as 24-bit and the report says *depth assumed*.

**Q6. Does our own rate switch make the engine stop itself after we restart it?** Count
`AVAudioEngineConfigurationChangeNotification` deliveries per switched track change (a log
line in the observer at `AudioPlayer.m:~187`) and watch `handleEngineConfigurationChange`'s
branch: `graphHealthy` → no-op is the expected outcome. If instead the engine stops itself
*after* `startEngineAndPlayNode:` and recovery rebuilds the graph, Phase 2's switch waits for
the notification as well as the rate read-back (the observer's queue hop already orders it
behind the current block, so the wait is "one more queue turn", not a listener). Also read
`outputNode.outputFormatForBus:0` and `mainMixerNode.outputFormatForBus:0` after the restart:
both at the new rate means AVAudioEngine re-derived the last connection by itself, which is
what today's different-rate device switches rely on; a stale mixer rate means Phase 2 also
reconnects `mainMixerNode → outputNode` at the new rate while stopped.

**Q8 (found in review, 2026-09-15). Hogging the system default output device.** coreaudiod moves
the default to another device the moment a process hogs the current one, and AVAudioEngine's
output unit is a *default* output unit: it follows the default whenever it moves, whatever
`kAudioOutputUnitProperty_CurrentDevice` was set to — during the hog write, or at a later
`start` — and follows it back when the release moves the default home. Measured with
`hogfollow.swift` (vibe-debug skill; phase 1 is the running engine, phase 2 the stopped one). Re-binding the unit and `prepare`-ing
after the take held in the standalone experiment but not in the app: a 5 s stall in `start`,
the unit on the other device afterwards, and after a switch away the audio on the wrong device.
Decision: the system default output device is never hogged (`VibeBitPerfectShouldHog`'s second
argument); bits still arrive unchanged, the caption says "shared, because it is the system
output device", and exclusivity means picking another system output in Sound settings. Open
to revisit if a supported way to pin AVAudioEngine's output unit turns up.

**Q7. A real DAC.** When a USB DAC is attached (not at planning time): repeat Q1 for the
switch time and Q3 for hog, read its `AvailablePhysicalFormats` (expect `i16`/`i24`/`i32`
rows per rate), and confirm the depth rule picks the highest integer depth and the report
says `24-bit`. A switch measured in seconds is the trigger for the async wait shape under
Phase 2.

## Phase 1 — the accessors and the rules

### 1a. `CoreAudioUtil` (`Vibe/Audio/Mac/Devices/CoreAudioUtil.{h,m}`)

Six methods in the file's own convention — one property each, `BOOL` success separate from
the answer, `kAudioObjectUnknown` refused up front, `AudioObjectHasProperty` before an optional
read:

```objc
+ (BOOL)readTransportType:(UInt32 *)transportType forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)readNominalSampleRate:(Float64 *)rate forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)setNominalSampleRate:(Float64)rate forDeviceID:(AudioDeviceID)deviceID;
// The first output stream, its current physical format and the formats it offers.
// availableFormats is malloc'd by the callee and owned by the caller.
+ (BOOL)readOutputStream:(AudioStreamID *)stream
          physicalFormat:(AudioStreamBasicDescription *)format
        availableFormats:(AudioStreamRangedDescription * _Nullable * _Nonnull)availableFormats
                   count:(UInt32 *)count
             forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)setPhysicalFormat:(AudioStreamBasicDescription)format forStream:(AudioStreamID)stream;
// 'vmvc'; a device with no software volume answers YES with *volume = 1.0.
+ (BOOL)readVirtualMainVolume:(Float32 *)volume forDeviceID:(AudioDeviceID)deviceID;
// Reads first: the HAL's set TOGGLES ownership (see the TRAP in the header).
+ (BOOL)readHogOwner:(pid_t *)owner forDeviceID:(AudioDeviceID)deviceID;
+ (BOOL)setHogOwnedByThisProcess:(BOOL)owned forDeviceID:(AudioDeviceID)deviceID;
```

`setHogOwnedByThisProcess:` is the one method with a decision in it, and it is the smallest
one possible: read the owner; if `owned` and the owner is already us, or `!owned` and the
owner is not us, return YES without writing; otherwise write once and read back. The TRAP
comment goes on it, spelled `TRAP:`.

### 1b. `OutputFormatRules.h` (`Vibe/Audio/Mac/Devices/`, header-only, `static inline`)

Foundation and CoreAudioTypes only, so the host-less suite compiles it.

```c
typedef NS_ENUM(NSInteger, VibeBitPerfectStatus) {
    VibeBitPerfectStatusOff,               // the setting, or an ineligible device (defensive:
                                           // the shell never lets the two coincide)
    VibeBitPerfectStatusIdle,              // on, device chosen, nothing playing
    VibeBitPerfectStatusActive,
    VibeBitPerfectStatusRateUnsupported,   // the device does not offer the file's rate; a
                                           // multiple was used when it offered one
    VibeBitPerfectStatusSwitchFailed,      // the HAL did not take the format in time
    VibeBitPerfectStatusDepthInsufficient,
    VibeBitPerfectStatusVolumeScaled,      // software volume below 1.0
    VibeBitPerfectStatusExclusiveRefused,  // hog held by another process
    VibeBitPerfectStatusSourceLossy,       // everything held, but the file is MP3/AAC:
                                           // the decoded audio is delivered unchanged
    VibeBitPerfectStatusFXGraphPresent,    // this run was launched with FX; inert until relaunch
};

typedef struct {
    VibeBitPerfectStatus status;
    double sampleRate;      // the device's, after the switch
    UInt32 bitsPerChannel;  // 0 for float
    BOOL isFloat;
    BOOL exclusive;
    float softwareVolume;
} VibeBitPerfectReport;

// PCM: mBitsPerChannel. ALAC (and, per Q5, FLAC): the kAppleLosslessFormatFlag_*
// source-depth flags. Lossy and unknown: 0, meaning "no native depth to honor".
static inline UInt32 VibeSourceBitDepth(AudioStreamBasicDescription source);

// YES when `physical` delivers `source` unchanged: same rate, and float32 or an
// integer depth >= the source's (a float source counts as 32). The report's
// depth check, not the chooser's preference.
static inline BOOL VibePhysicalFormatSatisfies(AudioStreamBasicDescription physical,
                                               AudioStreamBasicDescription source);

// Whether the mode may be on with this device: explicitly chosen (never the
// system default) and on a transport that carries bits unchanged — an ALLOWLIST:
// BuiltIn, PCI, USB, FireWire, Thunderbolt, HDMI, DisplayPort, AVB and Virtual.
// Bluetooth, AirPlay, Continuity, Remote*, Aggregate, AutoAggregate and Unknown
// are out; so is anything Apple adds later, until argued in. Read by the switch,
// the Output menu and the report, so the three cannot disagree.
static inline BOOL VibeBitPerfectDeviceEligible(BOOL isSystemDefault, UInt32 transportType);

// The rate rule: exact, else the smallest integer multiple offered, else 0.
static inline double VibeBitPerfectTargetRate(double sourceRate,
                                              const AudioStreamRangedDescription *formats,
                                              UInt32 count);

// The depth rule at `rate`, as-is: the integer format whose depth equals the
// source's (a lossy source takes 24), else the smallest integer depth above it,
// else float32. `current` is returned unchanged when it is already the answer,
// so an unneeded write never happens. Returns NO when nothing is at `rate`.
static inline BOOL VibeBitPerfectChooseFormat(AudioStreamBasicDescription current,
                                              AudioStreamBasicDescription source,
                                              double rate,
                                              const AudioStreamRangedDescription *formats,
                                              UInt32 count,
                                              AudioStreamBasicDescription *chosen);

// Whether a transport is hogged at all: everything but 'virt'.
static inline BOOL VibeBitPerfectShouldHog(UInt32 transportType);

// The fold, in priority order, so two breakers never race for the caption:
// Off > FXGraphPresent > Idle > RateUnsupported > SwitchFailed >
// DepthInsufficient > VolumeScaled > ExclusiveRefused > SourceLossy > Active.
// FXGraphPresent sits second because the mode is inert in such a run — nothing
// below it was even attempted. SourceLossy is last before Active because it is
// the only status that says the chain is perfect and the file is not. There is
// no pitch input: under the mode there is no varispeed to have a pitch.
static inline VibeBitPerfectStatus VibeBitPerfectFold(BOOL enabled, BOOL eligibleDevice,
        BOOL hasTrack, BOOL fxGraph, BOOL rateExact, BOOL switched, BOOL depthOK,
        float softwareVolume, BOOL hogWanted, BOOL hogHeld, BOOL sourceLossless);
```

`make check-vocabulary` rule 3 requires the `*Rules.h` name for a header-only seam with no
`.m` beside it, which this is.

### 1c. `Tests/OutputFormatRulesTests.m`

Added to the `VibeTests` source list in `project.yml` (`:579` is the `Tests` path; the header
needs no source entry of its own). Cases, each built from hand-written
`AudioStreamRangedDescription` arrays:

- the four devices in the table above, verbatim, for the rate rule: 44.1 on the speakers →
  44100; 44.1 on the AirPods (24k/48k) → 0; 176.4 on the speakers → 0 (no multiple offered);
  22.05 on the speakers → 44100 (2×) — and a USB-DAC-shaped list with `i16`/`i24`/`i32` rows
  at 44.1/48/96/192 for the as-is depth rule: a 16-bit source chooses `i16` even with a
  current `i32`; a 24-bit source chooses `i24`; a 20-bit ALAC source chooses `i24` (the
  smallest above); a lossy source chooses `i24`; a 32-bit source on a DAC topping out at `i24`
  chooses `i24` and `VibePhysicalFormatSatisfies` then says NO; a current format that is
  already the answer comes back unchanged;
- `VibeBitPerfectDeviceEligible`: the system default NO whatever its transport; every one of
  the eighteen SDK transports asserted individually — the nine allowed YES, the nine others
  and `kAudioDeviceTransportTypeUnknown` NO — so adding a constant to either side is a
  deliberate test edit;
- `VibeSourceBitDepth` for PCM 16/24/32, float32 (→ 32), ALAC flags 1–4, `'flac'` per Q5,
  `'.mp3'` and `'aac '` → 0;
- `VibePhysicalFormatSatisfies`: float32 satisfies 16 and 24 and not 32; `i24` satisfies 16
  and 24; `i16` does not satisfy 24; a rate mismatch never satisfies;
- the fold's priority, one assertion per adjacent pair, so a reorder is a test failure;
- `VibeBitPerfectShouldHog`: `'virt'` NO, `'usb '`/`'bltn'`/`'blue'`/`'hdmi'` YES.

`make test` green before Phase 2 begins.

## Phase 2 — the player

All in `AudioPlayer+Devices.m` and its header unless named otherwise; three one-line guarded
hooks in shared files.

### 2a. State (`AudioPlayerInternal.h`, inside the existing `#if TARGET_OS_OSX` block at `:153`)

```objc
    // The setting's queue-side intent, carried by setBitPerfectOutput: like _levelsWanted.
    BOOL                    _bitPerfectWanted;
    // The device this process currently hogs, or kAudioObjectUnknown. Queue-confined.
    AudioDeviceID           _hoggedDeviceID;
    // The one device whose format this run changed and has not yet put back, and
    // the physical format it had before the first change. kAudioObjectUnknown when
    // nothing is owed. Queue-confined; restoreOutputFormatOnQueue clears both.
    AudioDeviceID           _changedFormatDeviceID;
    AudioStreamBasicDescription _formatBeforeChange;
    // A settlement waiting for the outgoing audio to go silent before it may stop the
    // engine for a format switch; run once by completeRetiredFadePair: at count zero.
    dispatch_block_t        _parkedSettlement;
    // Published for the shell's readout, under _stateLock.
    VibeBitPerfectReport    _bitPerfectReport;
```

`AudioPlayer.h`'s `(Devices)` category (`:219`) gains `@property (atomic) BOOL bitPerfectOutput;`
with the contract in the decisions table, `- (void)prepareForTermination;` (*restores any
changed device format and releases the hog, synchronously; the app delegate's
`applicationWillTerminate:` is the one caller*), and `@property (readonly) VibeBitPerfectReport
bitPerfectReport;` beside `outputAudioActive`'s shape (`:196`) — a locked snapshot, no queue hop.
`OutputFormatRules.h` is imported by `AudioPlayer+Devices.h`, which `AudioPlayer.h` does not
import, so the struct is forward-usable there only through the `(Devices)` interface — put the
report getter in `+Devices.h`'s `(DevicesInternal)` block if the public header would otherwise
need the rules header, and expose it to the shell through `+Devices.h`, which the mac shell
may import (it already imports the mac-only `AudioDeviceManager.h`).

### 2b. Prepare, acquire, release

```objc
// Runs on _queue with the engine STOPPED or about to be started. Reads the bound
// device's capabilities, applies the rate and depth rules, writes one physical
// format if a switch is needed, waits (bounded) for the nominal rate to read back,
// and publishes the report. It never stops the engine itself: the caller has
// (device switch) or the park below has made stopping safe.
- (void)prepareOutputOnQueueForFile:(AVAudioFile *)file;
// Whether prepareOutputOnQueueForFile: would write a format — the park's predicate.
- (BOOL)outputNeedsSwitchOnQueueForFile:(AVAudioFile *)file;
// Hog for the bound device, when the mode, an explicit device and a non-virtual
// transport all hold. Idempotent through readHogOwner:.
- (void)acquireExclusiveOutputOnQueue;
- (void)releaseExclusiveOutputOnQueue;
// Writes _formatBeforeChange back to _changedFormatDeviceID when one is owed and
// clears the slot either way — a vanished device fails the write and is simply
// forgotten. No read-back wait: the HAL owns the change once the call returns.
- (void)restoreOutputFormatOnQueue;
```

`prepareOutputOnQueueForFile:` in order: the four early outs (`!_bitPerfectWanted`; `_fx != nil`,
the inert FX-graph run; an ineligible device — defensive, since the shell never lets the mode
be on with one; manual rendering) each publish their status and return; read stream, physical format, available formats and software volume; `target =
VibeBitPerfectTargetRate(...)`; `VibeBitPerfectChooseFormat(...)`; if the chosen format
differs from the current: `[_engine stop]` is **not** called here — assert `!_engine.isRunning`
instead, because both callers guarantee it — **remember the current format in the slot when
the slot is empty or names another device** (a switch-away already restored that one), write,
then poll `readNominalSampleRate:` at 5 ms until it equals the target or the Q1 deadline
passes; publish the report through the fold. `LogInfo` one line per switch ("bit-perfect:
<device> → 96000 Hz i24 in 87 ms").

**If Q6 requires it:** after the write, also `[_engine connect:_engine.mainMixerNode
to:_engine.outputNode format:<standard format at target rate>]` — which `installMasterBusOnQueue`
already does once for the FX-off graph, so lift that connect into a helper both call rather
than writing it twice. (The FX-on graph never reaches here: the mode forced `enableFX:NO`.)

`acquireExclusiveOutputOnQueue`: no-op unless `_bitPerfectWanted`, no FX graph, an explicit
device, a non-manual engine and `VibeBitPerfectShouldHog(transport)`; then
`setHogOwnedByThisProcess:YES`, record `_hoggedDeviceID`, and fold `ExclusiveRefused` into the
report on failure. `releaseExclusiveOutputOnQueue`: `setHogOwnedByThisProcess:NO` on
`_hoggedDeviceID` when set, then clear it.

### 2c. The hooks

- `AudioPlayer.m:713` `finishPlayOnQueueWithFile:…` — **before** `consumeRequest:` at `:714`:

  ```objc
  #if TARGET_OS_OSX
      if (file && _activeRetiredOutputCount > 0 && [self outputNeedsSwitchOnQueueForFile:file]) {
          // The switch stops the engine, which would cut a still-fading node
          // mid-waveform. Park until the outgoing audio is silent, then re-enter;
          // consumeRequest: drops a re-entry a newer play or a stop has superseded.
          [self preemptRetiredFadesOnQueue];
          __weak AudioPlayer *weakSelf = self;
          _parkedSettlement = ^{
              [weakSelf finishPlayOnQueueWithFile:file error:error openRequestId:openId];
          };
          return;
      }
  #endif
  ```

  and after `consumeRequest:` succeeds, before `attachConnectedNodeForFormat:` at `:739`:
  `#if TARGET_OS_OSX` — if a switch is needed: `[_engine stop]` (nothing is audible now:
  either nothing was counted, or the park ran), then `[self prepareOutputOnQueueForFile:file]`.
  The last-writer-wins slot is fine: the same-path prefetch race can deliver twice, both
  handles open the same file, and whichever re-entry runs first consumes the request.

- `AudioPlayer+Fades.m:117` `completeRetiredFadePair:` — after the decrement at `:125`, when
  the count reaches zero: run and clear `_parkedSettlement` (guarded `#if TARGET_OS_OSX`).
  A park with nothing counted never happens, because the predicate above requires the count.

- `AudioPlayer+Engine.m:20` `startEngineAndPlayNode:` — inside `if (!_engine.isRunning)`,
  before `:28`: `#if TARGET_OS_OSX [self acquireExclusiveOutputOnQueue]; #endif`.
  `scheduleEngineIdleStopOnQueue` — after `:66` and `:83`: `[strongSelf releaseExclusiveOutputOnQueue]`,
  same guard. Two sites, one line each; folding them into a "stop for idle" helper is optional.
  The delay at `:12` becomes two constants, `kEngineIdleStopDelaySeconds` = 10 and
  `kEngineIdleStopDelayHoggedSeconds` = 6, and the `dispatch_after` at `:55` picks by
  `_hoggedDeviceID != kAudioObjectUnknown` (iOS, which never hogs, gets the 10). The header
  comment's "long enough to absorb even a slow next-track open" reasoning holds for both.

- `AudioPlayer+Devices.m:158` `configureOutputDeviceOnQueue:` — before `setOutputUnitDevice:`
  at `:191`: `[self releaseExclusiveOutputOnQueue]` (the old device must not stay hogged) and,
  **when the target differs from `_changedFormatDeviceID`**, `[self restoreOutputFormatOnQueue]`
  (leaving a device puts it back; a switch onto the same device — the mode toggle — keeps the
  slot). Inside `if (shouldRestore)` at `:198`, `[self prepareOutputOnQueueForFile:file]` after
  the nil check and before `attachConnectedNodeForFormat:`; and because that restore reuses the
  track's varispeed, detach and nil `_varispeed` first when the mode is on, so the reconnect
  goes node → mixer. `startEngineAndPlayNode:` then re-hogs the new device on its own.

- `AudioPlayer.m:627-629` — the varispeed mint in `retireOutgoingChainOnQueueWithDeclick:`
  becomes `_varispeed = _bitPerfectWanted ? nil : newVarispeed` (guarded; iOS always mints),
  and `connectNode:throughVarispeedWithFormat:` (`+Graph.m:21`) connects `node` straight to
  `mainMixerNode` when `self.varispeed` is nil. `retireNode:varispeed:` and
  `detachRetiredFadePair:` already take a nil varispeed. The pitch setter's
  `self.varispeed.rate = …` is then a message to nil — and the shell has set the pitch to 0
  anyway.

- `AudioPlayer.m:398` `dealloc` — `restoreOutputFormatOnQueue` then
  `releaseExclusiveOutputOnQueue` inside the queue block, beside `[engine stop]`, guarded.
  `prepareForTermination` is the same pair through `runSyncOnQueue:`, and
  `AppDelegate.applicationWillTerminate:` (`:313`) calls it beside `saveLastPlaylist` — the
  player is never deallocated at quit, so this is the edge that keeps the restore promise.

- `resetToStoppedStateOnQueue` (`AudioPlayer.m:883`) and `stopOnQueue` (`:1043`) need nothing:
  the idle stop they schedule releases the hog, and a parked settlement dies at the re-entry's
  `consumeRequest:` because `invalidate` ran. `dropEngineBoundStateOnQueue` is iOS-only in
  practice and clears nothing here.

### 2d. The setting's entry

```objc
- (void)setBitPerfectOutput:(BOOL)on {          // main thread, like levelsEnabled
    dispatch_async(_queue, ^{
        self->_bitPerfectWanted = on;
        if (!on) {
            [self restoreOutputFormatOnQueue];       // the device as it was found
            [self releaseExclusiveOutputOnQueue];
        }
        else if (self->_fx) {
            [self publishBitPerfectReportOnQueue];   // → FXGraphPresent; inert until relaunch
            return;
        }
        NSInteger requested = self.currentlyRequestedAudioDeviceId;
        if (requested >= 0) {
            // A device switch onto the same device: stop, rebuild the chain with or
            // without the varispeed, prepare (on) and restore at position.
            [self configureOutputDeviceOnQueue:(AudioDeviceID)requested];
        } else {
            [self publishBitPerfectReportOnQueue];   // → Off (the shell never sends on here)
        }
    });
}
```

`configureOutputDeviceOnQueue:` with a Stopped or Loading player restores nothing and simply
leaves the report at Idle; the next settlement prepares. Turning the mode off through it is
what hands the current track a fresh varispeed again, so the fader that reappears works on the
track that is playing rather than on the next one.

### 2e. Debug

`DebugStateDump.m:46`'s player block gains `bitPerfect: {enabled, status, sampleRate, bits,
isFloat, exclusive, softwareVolume, hoggedDeviceId, restoreOwedToDeviceId}` from the report
plus one queue-hop read of `_hoggedDeviceID` and `_changedFormatDeviceID` through
`AudioPlayer+Debug.h` (the `currentlyActiveAudioDeviceId` shape,
`Vibe/Debug/AudioPlayer+Debug.h`). `varispeedPresent` joins `debugEngineCounts`, so a soak can
assert the chain shape, and `crossfadeMilliseconds` — the value the player was actually told —
joins the player block beside `pitch`, since nothing reports it today. `DebugCommandTable.m:340`'s `set_pause_at_track_end` is the
template for `set_bit_perfect <on|off>`, which writes the setting and requests the effect.

## Phase 3 — the setting, the pane, the header

### 3a. Store (`AppSettings+Mac.{h,m}`)

`SETTING_BIT_PERFECT_OUTPUT @"AudioPlayer.bitPerfectOutput"` beside `:34`, `@(NO)` in the
defaults at `:100`, `bitPerfectOutput`/`setBitPerfectOutput:` beside `:623`, declared beside
`audioFXEnabled` (`AppSettings+Mac.h:260`) with the contract: *explicit device only; turns FX
completely off while on; the writer requests `VibeSettingsLiveEffectBitPerfect |
VibeSettingsLiveEffectFXControls`.*

Beside it, two derived reads with no keys of their own. **`audioFXAllowed`** —
`audioFXEnabled && !bitPerfectOutput` — with the contract *the one answer to "do FX exist for
the user"; every gate reads this and never `audioFXEnabled`, which is only the stored choice the
Playback pane's switch displays.* The four gates and the clear move to it:
`MainPlayerController.m:142`, `MainMenuBuilder.m:417`, `MainPlayerController+Menus.m:38`,
`TransportKeyMonitor.m:290`, `MainPlayerController+Settings.m:117`. And
**`effectiveCrossfadeMilliseconds`** — `bitPerfectOutput ? kFadeDurationMilliseconds :
crossfadeMilliseconds` — *what the player is told; `crossfadeMilliseconds` stays the stored
choice the popup displays.* The one push site (`+Settings.m:51`) moves to it. The
`audioFXEnabled` and `crossfadeMilliseconds` contracts each gain one sentence pointing at their
derived twin.

### 3b. Effect (`MainPlayerController+Settings.{h,m}`)

`VibeSettingsLiveEffectBitPerfect = 1UL << 21` after `:50`; in `applySettingsLiveEffects:`,
beside the crossfade push at `:50`: `self.audioPlayer.bitPerfectOutput = settings.bitPerfectOutput;`,
and when it is on, `self.audioPlayer.pitch = 0` and `[window setPitchPanelShown:NO animate:YES]`
(the fader mirrors the player at `MainPlayerController.m:1136`, so it snaps to center by
itself); then `[self updateFXIndicators]`. **The pane requests
`BitPerfect | FXControls | Crossfade` together**: the FX branch at `:116`, now reading
`audioFXAllowed`, is what clears the five effects and hides the menu — exactly what the FX
switch's own off does — and the Crossfade branch, now pushing `effectiveCrossfadeMilliseconds`,
is what drops the crossfade to the minimum and lets `setCrossfadeMilliseconds:` re-arm the
splice; so the mode toggle, the FX toggle and the crossfade popup cannot reach the player three
different ways. `MainPlayerController.m:142` becomes `enableFX:settings.audioFXAllowed`.

**The pitch gates.** View > Show Pitch Control's ViewToggle validation (`+Menus.m:27`)
returns `!settings.bitPerfectOutput` for `kVibeMenuShowPitch` alone, and the P key
(`TransportKeyMonitor.m:251`) is swallowed under the same condition, so a bare P cannot reveal
a fader that would do nothing. `MainWindow.m:379`'s launch restore of `pitchPanelShown` reads
the same condition, so a relaunch with the mode on does not bring the panel back. Nothing else
about pitch changes: the range setting, the fader's own code and `playbackRate` are untouched,
because a pitch of 0 makes every consumer already correct.

### 3c. Pane (`SettingsGeneralViewController.m`), the Output menu and the fallback

A second row in the Audio section at `:84`: `STR_SETTINGS_BIT_PERFECT` ("Bit-perfect output")
with a caption that is the report's sentence, rendered by a `captionForReport:` switch over
`VibeBitPerfectStatus` — one `STR_SETTINGS_BIT_PERFECT_*` per status, with the *Off* case
showing the explanatory caption ("Sets the device to each file's sample rate and bit depth,
and keeps other apps off it while playing"). **The switch is enabled only for an eligible
device**: `refreshFromSettings` (`:103`) looks the requested device up through
`AudioDeviceManager.outputDeviceForId:` and asks `VibeBitPerfectDeviceEligible`; disabled, the
caption is `STR_SETTINGS_BIT_PERFECT_NEEDS_DEVICE` ("Choose a wired output device in the Output
menu to enable bit-perfect output"). The base class re-runs `refreshFromSettings` on every
key-window change, and the pane already observes device changes (`:129-139`), so the switch
follows the Output popup beside it. The toggle action mirrors `toggleAlwaysOnTop:` (`:113`) and
requests the effect. When `self.playerController.audioPlayer.fx != nil` and the mode is on,
the caption is `STR_SETTINGS_ENABLE_FX_RESTART` — the same string, the same reason.

**The Output menu** (`OutputDevicesMenuController.m:90` and `:105`): `enabled` becomes
`!bitPerfectOutput || VibeBitPerfectDeviceEligible(device.isSystemDefault, device.transportType)`
— System Output and every Bluetooth device gray out while the mode is on, in the menu bar and
in the Settings popup alike, since one controller builds both. `AudioDevice` gains a readonly
`transportType` (`UInt32`, `kAudioDeviceTransportTypeUnknown` when unreadable) filled by
`readDeviceForID:` (`AudioDeviceManager.m:52`) through the new `readTransportType:forDeviceID:`;
**a failed read leaves it Unknown and never marks the sweep incomplete** — the AirPlay
investigation's TRAP, because a device that vanishes from the list is worse than one whose
transport is unknown. `isEqual:`/`hash` stay `deviceId`-only.

**The fallback.** `didChangeOutputDevice:` (`+PlayerEvents.m:325`) already persists System
Output when a chosen device vanishes; when it lands on `-1` with the mode on, it also writes
`bitPerfectOutput = NO` and requests `BitPerfect | FXControls | Crossfade`, so the mode never
survives onto a device it cannot drive. That is the one place the mode is turned off by the app
rather than the user, and it logs why.

`SettingsPlaybackViewController.m:111`: `_enableFXSwitch.enabled = !settings.bitPerfectOutput;`
and the crossfade popup likewise, both rows captioned `STR_SETTINGS_OFF_WHILE_BIT_PERFECT`
("Off while bit-perfect output is on") in that state — one string for both, and on the FX row
it outranks the restart caption at `:80`, which would otherwise promise FX after a reopen that
the mode will refuse.

### 3d. Header (`TrackDisplayController.{h,m}`, `MainPlayerController+Transport.m`)

`VibeFXDisplayState` (`TrackDisplayController.h:34`) gains a three-valued `bitPerfect` field —
none, open, closed (the struct's comment widens from "which performance effects are on" to
"deck state riding the codec line"); `fxSymbolNames` (`.m:168`) appends `lock.fill` or
`lock.open` **last**, so it sits against the codec text it qualifies; `renderFXState:` also
sets `fileMetadataTextField.toolTip` to the status sentence for the open lock and to nil
otherwise (the field is one label, so the whole codec line is the hover target — acceptable,
the line is short). `updateFXIndicators` (`+Transport.m:168`) fills both from
`audioPlayer.bitPerfectReport` (closed for Active, open for any other status while the mode is
on, none when off) and is additionally called from `performPerTrackRefreshForStartedTrack:`
(`+PlayerEvents.m:106`) and `didChangeOutputDevice:` (`:325`). The status sentences are the
same `STR_SETTINGS_BIT_PERFECT_*` strings the pane caption uses — one spelling per reason.
Renaming it `updateDeckIndicators` is the consolidating pass's call.

### 3e. Strings

`STR_SETTINGS_BIT_PERFECT`, one caption per `VibeBitPerfectStatus` (ten; *Idle* and *Active*
carry `%@` for the format), `STR_SETTINGS_OFF_WHILE_BIT_PERFECT`, and the format fragment
("%@ kHz · %@-bit · exclusive", built from `Formatters.decimalString:` like `fileInfoLine`),
plus `STR_SETTINGS_BIT_PERFECT_NEEDS_DEVICE`. `make strings` and **English only** — the wording
will move while the feature is tuned, and the thirty-language pass through the `vibe-strings`
skill is the release's job; `make check-translations` is the gate that holds a release until
it is done, which is the point of it. No new menu string: the Output menu's items only gain an
enabled state.

### 3f. Docs

- `Audio/Mac/Devices/CLAUDE.md`: a *Bit-perfect output* section carrying the hog-toggle TRAP,
  the park, the "format rides the settlement, hog rides the engine" rule, and the no-restore
  decision — every call site is in this directory or one guarded line away, so this is the
  rule's home; **no new root-level guarantee**.
- `Audio/CLAUDE.md`: one sentence under `+Engine` (the two hog edges) and one under *Prefetch,
  idle and gapless* (the park precedes `consumeRequest:` and re-enters through it).
- `Mac/Settings/CLAUDE.md` and `Mac/MainWindow/APPEARANCE.md`: the pane row and the lock glyph.
- `README.md` features and `CHANGELOG.md`: one line each.

## Phase 4 — verification

All gates: `make test`, `make analyze CONFIG=Release`, `make check-layout`,
`make check-vocabulary`, `make check-strings`, `make check-translations`, `make build-ios`
(the new header sits under `Mac/`, and every hook is guarded, so iOS must build untouched).

**The loopback, kept as the regression oracle** (`verify-bit-perfect.swift`, from Q2), with
Vibe launched `VIBE_AUDIBLE=1` on BlackHole 2ch at 100 % software volume, mode on:

```bash
B=build/DerivedData/Build/Products/Debug/Vibe.app/Contents/MacOS/Vibe
$B --debug-cmd set_bit_perfect on
for f in Assets/test_audio_files/rates/*; do
  .claude/skills/vibe-debug/scripts/verify-bit-perfect.swift "$f" 6 &   # records BlackHole
  $B --debug-cmd open "$f"; wait
done
$B --debug-cmd dump_state | jq .player.bitPerfect      # status active, sampleRate = the file's
# then BlackHole at 44 % in Audio MIDI Setup and one file again: mismatches expected, status volumeScaled
```

Expected per file: capture rate equals the file's rate, zero mismatched frames after the
fade-in, and the report `active`. Then the two negative checks: BlackHole at 44 % → mismatches
and `volumeScaled`; a run launched with FX on → `fxGraphPresent`.

**Withdrawal.** In a run launched with FX on and the mode off: `dump_menu` shows `menu_fx`
visible; `set_pitch 3`, `toggle_pitch_panel` on; `set_bit_perfect on`; then `dump_menu` shows
`menu_fx` `hidden: true` with empty key equivalents and Show Pitch Control disabled, `key q`
leaves `dump_state`'s `lowKill` false, `key p` leaves the panel hidden, `dump_state` reads
`pitch: 0`, `crossfadeMilliseconds: 10` and `bitPerfect.status: fxGraphPresent`, and
`settings_open playback` + `dump_settings_ui` shows the FX switch and the crossfade popup
disabled; `set_bit_perfect off` brings the menu, the keys, the popup and the panel toggle back.
Relaunch with the mode on: every FX field in `dump_state` reads 0 (`player.fx` is nil),
`debugEngineCounts.varispeedPresent` is 0 while a track plays, and the status has moved past
`fxGraphPresent`.

**Eligibility.** With the mode on and the speakers chosen: `dump_menu` on the Output menu
shows System Output and the AirPods `enabled: false`, the speakers and BlackHole enabled
(ZoomAudioDevice too — virtual is allowed, and graying it would be a transport rule lying
about a device it cannot tell from BlackHole);
`settings_open general` + `dump_settings_ui` shows the popup's same items disabled and the
switch enabled. Choose the AirPods with the mode off: the switch is disabled and its caption
names the Output menu. Then the fallback: mode on, on BlackHole, and BlackHole removed from
the system (its driver unloaded, or a USB DAC unplugged when hardware is present): `dump_state`
shows the device at `-1` and `bitPerfect.enabled: false`, and the log line says why.

**The idle delays.** Mode on, play, pause: `dump_state` shows `exclusive: false` between 6
and 7 s later. Mode off, play, pause: the engine still reports running at 9 s and stopped by
11 s (`debugEngineCounts`, or the existing `player` block's engine state).

**Restore.** Built-in speakers chosen explicitly (Appendix A's probe reads them at 48000
first), mode on, play the 96 kHz file: the probe reads 96000 and `dump_state` shows
`restoreOwedToDeviceId` set; `set_bit_perfect off`: the probe reads 48000 and the field clears.
Again mode on and the 96 kHz file, then switch the Output menu to BlackHole: the speakers read
48000. Again on the speakers, then `--debug-cmd quit`: the speakers read 48000 — that is
`prepareForTermination` having run.

**Exclusive access, audibly, once** (the AirPods trap in `vibe-debug`): built-in speakers
chosen explicitly, mode on, play; `say hello` silent; pause; after ~6 s `say hello` audible;
`dump_state` shows `exclusive: true` then `false`; Appendix A's probe agrees on the pid.

**Mixed-rate torture.** A folder of the `rates/` files repeated into ~40 rows, then
`make torture PLAYLIST=<folder>` on BlackHole with the mode on (`vibe-stress`), which hammers
skips and seeks across rate boundaries — the race surface this feature adds is the park racing
a newer play, a stop, a pause and a device switch, and `check_consistency` plus `dump_health`'s
`retiredFades`/`engineNodes` are the oracles for a park that never re-entered or a pair it
stranded. Add the config-change counter from Q6 to `dump_state` if it earned its keep; otherwise
delete it.

**The USB DAC checklist** (Q7, whenever hardware is present): rates 44.1 / 48 / 96 land with
the report naming `24-bit`; a 176.4 file on a DAC without it reports `rateUnsupported` and
plays; unplugging the DAC mid-play falls back to System Output as today (`+Devices.m:49`) and
the report reads `needsExplicitDevice`; plugging it back in and re-choosing it re-hogs.

## Phase 5 — the everyday chain

Not the mode: the requirement that the normal chain — FX graph present, every effect off,
pitch at 0 — delivers unchanged bits. Phase 0's everyday-chain measurement decides what this
phase is:

- **Sample-exact already.** Phase 5 is the measurement itself, kept as a Phase 4 regression
  line, and one sentence in `Audio/CLAUDE.md` saying the idle graph is transparent and how
  that is checked. Nothing changes.
- **The EQ is the culprit.** The two low-kill bands are parked at 20 Hz and never bypassed
  (`AudioFX.m:191`, `:203`) because toggling `bypass` live clicks. The candidate fix is to
  bypass a band only at the *parked end* of its sweep — where the filter's residual on program
  material is smallest — and un-bypass before a sweep starts, in `applyLowKillTargetOnQueue`.
  It has to be re-measured for clicks with the loopback (a bypass toggle is a discontinuity
  the oracle sees as a mismatch burst at the toggle), and the `.m`'s bypass-click trap is
  rewritten to say exactly when a toggle is safe.
- **The varispeed is the culprit.** `AVAudioUnitVarispeed` inherits `bypass` from
  `AVAudioUnitTimeEffect`; the candidate fix is bypass at pitch 0 and un-bypass on the first
  non-zero pitch, in `setPitch:`, again re-measured for clicks at the toggle.

Either fix is its own change with its own `Audio/CLAUDE.md` paragraph. Once the everyday
chain is proven transparent, the *inert in a run with the FX graph* restriction above becomes
removable — the graph would no longer be a reason to withhold the switch until relaunch — and
that is the follow-up to file, not something to build into Phases 2–3 ahead of the
measurement.

## Complexity budget, stated

- **New files: 1 shipping** (`Vibe/Audio/Mac/Devices/OutputFormatRules.h`), argued above, plus
  `Tests/OutputFormatRulesTests.m` and the skill script `verify-bit-perfect.swift` (not app
  code).
- **New types: 2**, both plain C in that header — `VibeBitPerfectStatus`, `VibeBitPerfectReport`.
  No class, no protocol, no coordinator, no notification, no timer.
- **Hand-written Objective-C: ≈ 580 lines** — ~130 in `CoreAudioUtil.m`, ~95 in the rules
  header, ~210 in `AudioPlayer+Devices.m` (restore and the termination hook included), ~30 of
  guarded hooks, the no-varispeed branch and the two idle delays across `AudioPlayer.m`,
  `+Graph.m`, `+Engine.m` and `+Fades.m`, ~35 in the store (the setting and the two derived
  reads), ~10 across the FX, pitch and crossfade gates, ~15 for `AudioDevice.transportType` and
  its sweep read, ~5 in the Output menu, one line in `AppDelegate.m`, ~50 across the two panes
  and the fallback, ~15 in the header glyph and tooltip; ~35 of debug. Tests ≈ 170. Phase 5 is
  unbudgeted until Phase 0 says whether it is a change at all.
- **Removed or unified:** the four sites that each spelled "FX exist for the user" as
  `fx != nil && audioFXEnabled` now read one derived answer, so the rule has one home, and the
  crossfade the player is told is likewise one derived read. The
  mixer→output connect in `installMasterBusOnQueue` becomes a helper
  the rate switch shares *only if* Q6 says a reconnect is needed. Otherwise this feature
  consolidates nothing in the engine, because the engine had no rate, depth or ownership
  handling to consolidate — the reads it adds are the first of their kind, which is also why
  they land in the one file whose job is raw HAL reads rather than anywhere new. It does land
  the transport-type read the AirPlay investigation designed, so that is not written twice
  later.
- **No new root-level guarantee.** The mode's rules have every call site in `Mac/Devices/` or
  one guarded line away, so `Mac/Devices/CLAUDE.md` holds them.

## Out of scope, and what each would cost

- **iOS.** `AVAudioSession.setPreferredSampleRate:` is a *preference* the system may ignore,
  there is no hog, no physical format and no per-device volume model; a wired USB DAC on an
  iPhone gets whatever the session negotiates. The right feature there is different and
  smaller — ask for the file's rate on activation — and belongs to `Audio/iOS/`'s session
  controller, not this plan.
- **Integer mode through a raw `AudioDeviceCreateIOProcID`**, bypassing `AVAudioEngine`.
  "Integer mode" is what Audirvana called delivering integer samples straight to the driver's
  physical format from the app's own IO callback, skipping CoreAudio's float32 client path
  entirely. The arithmetic above is why it buys nothing for sources up to 24 bits — the float
  path round-trips them exactly; for 32-bit sources it would, at the cost of replacing the whole
  engine's output side. Closed.
- **Making an idle FX graph transparent in-run**, by bypassing the two EQ bands with the
  engine stopped so the mode need not wait for a relaunch. It costs a bypass edge on both mode
  transitions against the EQ-bypass click trap in `AudioFX.m` (the off edge with the engine
  running), and rests on an unmeasured claim that a band-bypassed `AVAudioUnitEQ` is
  sample-exact. The shipped shape is the launch-time one FX already has; if the relaunch
  caption ever grates, measure that claim with the loopback before building anything.
- **DSD / DoP.** DSD is the 1-bit, 2.8 MHz-and-up sigma-delta stream SACDs are mastered in
  (`.dsf`/`.dff` files); DoP is the convention that packs those bits into 24-bit PCM frames a
  DSD-capable DAC recognizes and unpacks. Vibe does not read DSD files, and CoreAudio does not
  decode them, so there is nothing for the mode to deliver. Also: upsampling and oversampling
  options, a per-device memory of the switch, a
  multi-device restore table (the one slot above restores a device the moment it is left, so a
  table would only matter for a device left *without* passing through the switch path, which
  does not exist), and an app volume control (Vibe has none; adding one would be a gain stage
  this mode exists to remove).
- **Excluding Bluetooth or AirPlay transports by rule.** The rules operate on what the device
  *offers*; a Bluetooth device that offers only 48 kHz reports `rateUnsupported` for a 44.1
  file, which is the truth, and needs no transport-specific case. Add one only when a real
  device misbehaves under hog.

## Sources

- `CoreAudio/AudioHardware.h:932-942` (hog mode semantics), `:1018` (`'oink'`).
- `AudioToolbox/AudioHardwareService.h:49-71` (`'vmvc'`; "Master" deprecated, "Main" not).
- `CoreAudioTypes/CoreAudioBaseTypes.h:431` (`kAudioFormatFLAC`), `:544-547` (ALAC depth flags).
- `docs/not-doing/airplay-output-devices.md` — the transport-type read and the sweep's
  strictness rule this plan deliberately leaves alone.
- Appendix A, run 2026-09-14 on this machine (macOS 27.0 host, Xcode 26 SDK).

## Appendix A — the read-only HAL probe

Compile with `clang -o halprobe halprobe.c -framework CoreAudio -framework CoreFoundation`.
It writes nothing; it is what produced the table above and what Q3 and Q7 read the hog owner
with from outside the app.

```c
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>

static void fourcc(UInt32 v, char *o) { o[0]=v>>24; o[1]=v>>16; o[2]=v>>8; o[3]=v; o[4]=0; }
static void printStr(AudioObjectID id, AudioObjectPropertySelector sel, const char *label) {
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef s = NULL; UInt32 sz = sizeof s; char buf[256] = "(none)";
    if (AudioObjectGetPropertyData(id, &a, 0, NULL, &sz, &s) == noErr && s) {
        CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(s);
    }
    printf("  %s: %s\n", label, buf);
}
int main(void) {
    AudioObjectPropertyAddress devs = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0; AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devs, 0, NULL, &sz);
    AudioDeviceID *ids = malloc(sz); AudioObjectGetPropertyData(kAudioObjectSystemObject, &devs, 0, NULL, &sz, ids);
    for (UInt32 i = 0; i < sz / sizeof(AudioDeviceID); i++) {
        AudioDeviceID d = ids[i];
        AudioObjectPropertyAddress cfg = { kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        UInt32 csz = 0; AudioObjectGetPropertyDataSize(d, &cfg, 0, NULL, &csz);
        AudioBufferList *abl = malloc(csz); UInt32 ch = 0;
        if (AudioObjectGetPropertyData(d, &cfg, 0, NULL, &csz, abl) == noErr)
            for (UInt32 b = 0; b < abl->mNumberBuffers; b++) ch += abl->mBuffers[b].mNumberChannels;
        free(abl);
        if (!ch) continue;
        printf("Device %u (%u output channels)\n", d, ch);
        printStr(d, kAudioObjectPropertyName, "name"); printStr(d, kAudioDevicePropertyDeviceUID, "uid");
        AudioObjectPropertyAddress tt = { kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 t = 0, tsz = sizeof t; char tc[5] = "????";
        if (AudioObjectGetPropertyData(d, &tt, 0, NULL, &tsz, &t) == noErr) fourcc(t, tc);
        AudioObjectPropertyAddress nr = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Float64 rate = 0; UInt32 rsz = sizeof rate; AudioObjectGetPropertyData(d, &nr, 0, NULL, &rsz, &rate);
        printf("  transport: %s  nominal rate: %.0f\n", tc, rate);
        AudioObjectPropertyAddress ar = { kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 asz = 0; AudioObjectGetPropertyDataSize(d, &ar, 0, NULL, &asz);
        AudioValueRange *ranges = malloc(asz);
        if (AudioObjectGetPropertyData(d, &ar, 0, NULL, &asz, ranges) == noErr) {
            printf("  available rates:");
            for (UInt32 r = 0; r < asz / sizeof(AudioValueRange); r++) printf(" %.0f", ranges[r].mMinimum);
            printf("\n");
        }
        free(ranges);
        AudioObjectPropertyAddress hm = { kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        pid_t hog = -1; UInt32 hsz = sizeof hog; Boolean settable = 0;
        AudioObjectGetPropertyData(d, &hm, 0, NULL, &hsz, &hog); AudioObjectIsPropertySettable(d, &hm, &settable);
        printf("  hog mode: pid=%d settable=%d\n", (int)hog, settable);
        AudioObjectPropertyAddress vmv = { 'vmvc', kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        Float32 vol = -1; UInt32 vsz = sizeof vol;
        if (AudioObjectHasProperty(d, &vmv) && AudioObjectGetPropertyData(d, &vmv, 0, NULL, &vsz, &vol) == noErr)
            printf("  software volume: %.3f\n", vol);
        AudioObjectPropertyAddress vs = { kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        printf("  hardware volume property: %s\n", AudioObjectHasProperty(d, &vs) ? "yes" : "no");
        AudioObjectPropertyAddress st = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        UInt32 ssz = 0; AudioObjectGetPropertyDataSize(d, &st, 0, NULL, &ssz);
        AudioStreamID *streams = malloc(ssz); AudioObjectGetPropertyData(d, &st, 0, NULL, &ssz, streams);
        for (UInt32 s = 0; s < ssz / sizeof(AudioStreamID); s++) {
            AudioObjectPropertyAddress pf = { kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            AudioStreamBasicDescription f = {0}; UInt32 fsz = sizeof f;
            AudioObjectGetPropertyData(streams[s], &pf, 0, NULL, &fsz, &f);
            printf("  stream %u physical: %.0f Hz %s%u %uch\n", streams[s], f.mSampleRate,
                   (f.mFormatFlags & kAudioFormatFlagIsFloat) ? "f" : "i", (unsigned)f.mBitsPerChannel, (unsigned)f.mChannelsPerFrame);
            AudioObjectPropertyAddress apf = { kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            UInt32 apsz = 0; AudioObjectGetPropertyDataSize(streams[s], &apf, 0, NULL, &apsz);
            AudioStreamRangedDescription *fmts = malloc(apsz);
            if (AudioObjectGetPropertyData(streams[s], &apf, 0, NULL, &apsz, fmts) == noErr) {
                printf("    available:");
                for (UInt32 k = 0; k < apsz / sizeof *fmts; k++)
                    printf(" [%.0f %s%u]", fmts[k].mFormat.mSampleRate,
                           (fmts[k].mFormat.mFormatFlags & kAudioFormatFlagIsFloat) ? "f" : "i",
                           (unsigned)fmts[k].mFormat.mBitsPerChannel);
                printf("\n");
            }
            free(fmts);
        }
        free(streams);
    }
    free(ids);
    return 0;
}
```

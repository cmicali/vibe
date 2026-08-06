# Audio: playback engine, FX, metadata, devices, waveform data, BPM

## Playback engine

`AudioPlayer` drives an `AVAudioEngine` with a fresh `AVAudioPlayerNode` per track. Its state machine is `{Stopped, Playing, Paused, Loading}`; `Loading` covers the in-flight file open, reports `isPlaying` and gives a position and duration of zero.

**Threading.** Every engine mutation runs on a serial `dispatch_queue` (`com.vibe.audioplayer`, default QoS). The UI-facing getters — `position`, `duration` and `isPlaying` — read state under an `os_unfair_lock` and never block. Two generation counters sort out async work: `_generation` discards stale `scheduleSegment` completions, and `_rampGeneration` cancels in-flight volume fades, which stop, seek, skip and device switches all bump first. Every fade is asynchronous, so the queue never sleeps. `run_on_main_thread()` dispatches UI updates back to the main thread.

**Crossfades and seeks.** A track change crossfades on two independent chains, because each track gets its own `AVAudioUnitVarispeed`. `playOnQueue:` mints a fresh one for the incoming track, and `_varispeed` always points at the current or incoming track's. The outgoing node's live connection is therefore never rerouted: it fades out on its own varispeed and is detached, varispeed and all, once silent, while the incoming node fades in from silence on the new varispeed (`finishPlayOnQueue:`, same ramp generation). Reconnecting a live node reconfigures the graph and clicks, which is exactly what per-track varispeeds avoid; it also removes the mono-to-stereo output-unit restart, since each varispeed is connected once, for one format. The incoming fade-in stops the new track's first frame, rarely a zero crossing, from clicking too.

A seek while playing declicks *without reconnecting the graph at all*, because reconnecting a live node is itself a click on a running engine. `seekToPosition:` fades the current node down, reschedules it in place at the new frame inside the fade-out completion, then fades it back up, so both the `[node stop]` and the new segment's start land at silence. A paused seek simply reschedules the silent node in place.

**Robustness.** A last-valid-position cache preserves the playhead when the engine stops itself — on a device unplug or a format change — before recovery can read it. Files open off-queue with a timeout, so an undownloaded iCloud or Dropbox placeholder cannot wedge playback; a slow open surfaces a loading state instead. `stop`, the File > Close path, unloads outright: it supersedes any in-flight open so a Loading track never starts, fades a playing node to silence before teardown, and deliberately fires no delegate callback. It is not a track-end event, so it must not drive auto-advance, and the caller owns the UI reset.

**Prefetch and idle.** The controller calls `prefetchTrack:` on every track start to pre-open the playlist's likely next track; the next `play:` of that path consumes the parked `AVAudioFile`, so auto-advance and skip pay no file open. The engine stops when playback goes idle, which releases the output device, and restarts lazily on the next play. That idle stop is deferred by about two seconds and cancelled by generation in `startEngineAndPlayNode:`, so consecutive tracks reuse the running engine rather than pay an output-unit stop and start.

**Devices.** The async init resolves the saved output device on the player queue, by UID first and name as a fallback, which keeps device enumeration off the launch path's main thread. All device management — resolution, switching, config-change recovery, and parking or falling back when a device vanishes — lives in the `AudioPlayer+Devices` category. `AudioPlayerInternal.h`, a private class extension, declares the shared ivars and queue-side helpers both files use; the public device API sits in an `AudioPlayer (Devices)` block in `AudioPlayer.h`.

## Performance effects

`AudioPlayer` owns `AudioFX` and exposes it as the readonly `fx` property. It holds every DJ performance effect: the low-kill high-pass, with its Q key and W double-cutoff boost, and the send-returns — E for a long reverb wash, R and T for BPM-synced ping-pong delays on 1/8- and 1/16-note taps, fed by the controller through `delayTapBPM`.

`AudioFX` stores plain on-off state per effect. Telling a tap from a hold on the bare keys is `TransportKeyMonitor`'s job, not its. One coupling is enforced here rather than in the key layer, so that every path — key, menu and debug command — gets it: clearing `lowKillEnabled` also clears `lowKillBoostActive`. The boost modifies that filter, so a latched W must not outlive the low kill and hold the cutoff above where Q alone would put it while the low kill reads off.

The class owns the whole master-bus graph segment between `mainMixerNode` and `outputNode`: low-kill EQ, then a dry path plus gated parallel returns, then the master mix. `installInEngine:` wires it once on the player queue during the async init. The `AudioFX` object itself is created synchronously, so intent set before the engine exists is recorded and applied at install. Every toggle is click-free, with cutoff sweeps and gate fades on the player queue and generation-counter preemption like the player's volume ramps. Its .m comments record hard-won AVFAudio traps: MatrixReverb's stale header ranges assert in the render thread, mixer volume and pan writes before attach are dropped, and EQ bypass flips click.

## Metadata (`Metadata/`)

`AudioTrackMetadata` uses TagLib to extract the title, artist, album art and codec information. `AudioTrackMetadataCache` persists the results through PINCache with `NSSecureCoding`; `parsedOK` marks failed parses, which are shown but never cached.

The playlist scan runs in two stages on one four-worker queue. High-priority cache-check operations — a stat and a small disk read, never the audio data, so a dataless cloud placeholder cannot block them — sweep the whole playlist first and publish every previously seen track at disk speed. Misses re-enqueue as parse operations, with dataless placeholders demoted below local files so that a cloud-heavy folder cannot pin all four workers while fast local parses wait.

The current track skips the scan entirely. `MainPlayerController` calls `loadMetadataNow:` from `didBeginLoading:` and `didStartPlaying:`, and it runs in a persistent user-initiated priority lane, so the header's tags and art never queue behind the sweep. On a cache miss it skips the parse while the file is still dataless, because the player's own open is materializing that same file; the `didStartPlaying:` call retries once the file is local.

Album art has a memory lifecycle of its own. The disk cache stores only a 128px thumbnail JPEG. Full-resolution art is decoded on demand, capped at 1024px through ImageIO, for the current track alone, and `discardDecodedAlbumArt` demotes it when the track changes. No lock is ever held across file I/O or an image decode, because a cloud file can block a read indefinitely.

## Devices

`CoreAudioUtil` (in `Util/`) is a stateless set of raw HAL property accessors for device IDs, UIDs, names and output-channel checks.

`AudioDeviceManager`, a singleton, owns device-change listening. At init it registers CoreAudio listeners for the default output device and for the device list, keeps them for the life of the process and never removes them. It fans out to weakly held `AudioDeviceManagerObserver` objects — `AudioPlayer` and `OutputDevicesMenuController` — on the main thread in the common run-loop modes. GCD main-queue blocks do not run during menu tracking, and this way the devices menu refreshes while it is open.

## Waveform data (`Waveform/`) and BPM detection (`Analysis/`)

Rendering lives in `Vibe/Waveform/`; see its `CLAUDE.md`. This directory owns the data.

`AudioWaveform` is a C++ data structure storing one min/max float pair per chunk. `AVFAudioWaveformLoader`, backed by `AVAudioFile`, generates waveform data asynchronously and hands immutable snapshots to the main thread for progressive rendering. Cache lookups run on `AudioWaveformCache`'s serial loader queue, but the open and decode run on a global utility queue: the `AVAudioFile` open has no cancellation point and can block for minutes on a cloud placeholder, so off-queue it strands one worker rather than wedging every later track's waveform. `AudioWaveformCache` persists the data through PINCache.

`AudioBPMAnalyzer` (ObjC++ and Accelerate) detects tempo on the waveform loader's decode pass, so it costs no second file read. While streaming it builds a power-spectrum spectral-flux onset envelope. At end of file it runs autocorrelation and a harmonic comb over 60–200 BPM, then rescores the top candidates with a time-domain phase comb — refining each candidate's fractional period against the envelope over a window of 40 seconds or less — to resolve 2:1 and 3:2 metrical errors. A tolerance-free interpolated fine pass then polishes the winner's period: the coarse comb's jitter window flattens its score into a plateau about ±0.1 BPM wide, and the fine pass lands within roughly ±0.01 BPM on a steady tempo. Below a confidence gate it returns 0, which covers noise, speech and rubato. Measure it with the vibe-debug skill's `scan-bpm.sh`, a standalone scan that needs no app launch, against the generated `bpm-*.wav` loops.

The result travels in `CodableAudioWaveform.bpm`, arrives through `AudioWaveformCache`'s `audioWaveformCache:didDetectBPM:forURL:` and lands in the transient `AudioTrack.detectedBPM`. Deliveries can race a track change, so receivers must match the URL against the current track. A file's own tempo tag beats analysis: `AudioTrackMetadata.bpm` reads TagLib's PropertyMap "BPM", which covers ID3 TBPM, MP4 tmpo and Vorbis BPM. The BPM label under the codec label shows the winner, scaled live by the pitch fader.

The C++ waveform types stay out of ObjC headers. `AudioWaveformCache.h` forward-declares `CodableAudioWaveform` rather than importing `AudioWaveform.h`, so the UI layer compiles as plain ObjC.

# Reference: the audio-reactive equalizer indicator

The macOS playlist and iOS library draw the same five-bar playing marker from the
same demand-driven analyzer. This document records the shape of the finished design
and the traps that are easy to reintroduce.

## The two clocks

Audio analysis and visible motion deliberately do not share a clock:

1. `AudioLevelAnalyzer` makes about 24 decisions per second. For the complete windows
   in a roughly 100 ms tap callback, activity mode retains normalized per-band peaks;
   spectrum mode time-averages energy per octave and normalizes one coherent result.
   `AudioLevelTap` publishes that callback summary through `AudioLevelPublisher` as a
   five-level snapshot with a monotonic sequence.
2. `EqualizerIndicatorView` reads the latest sequence from its own display link,
   requested at 20–30 Hz. That link only polls snapshots and the 0.5-second staleness
   deadline. A new sequence retargets the materially changed bars with explicit
   scalar Core Animation animations: 0.135-second attack, 0.55-second release and
   ease-out timing, starting from each bar's current presentation scale.

Repeated polls therefore cost no FFT. Core Animation evaluates the explicit
animations at the display cadence — 60 fps on a 60 Hz display — so the app does not
need a 60 Hz callback or transform write loop to keep motion smooth. The analyzer
never knows how a view moves.

## Rendering

The indicator creates five pill-shaped `CALayer`s once. Geometry is rebuilt only
when bounds change, and implicit layer actions are permanently disabled. On a new
sequence, a bar whose target changed by at least 0.005 gets one model
`transform.scale.y` write and one explicit scalar animation from its current
presentation scale; unchanged bars get neither. Those writes are grouped in one
transaction. Animation objects are created per changed target, never per displayed
frame. No EQ tick calls `draw`, rebuilds a path, lays out the bars or invalidates a
waveform.

Level zero is the dot pose and level one is full height. When audio alone stops while
the row remains visible, the view invalidates the poller, balances demand and writes
the collapsed model pose once, then replaces each noncollapsed bar's keyed animation
with one 0.55-second release from its presentation scale. Core Animation finishes
that release without a display link, timer, callback or app-side frame loop. Geometry
or visibility loss, detachment and source replacement remove animations and settle
directly to dots, so motion based on invisible pixels, stale geometry or stale
ownership cannot survive. A missing `EqualizerLevelSource` is an inactive view, not
permission to run canned keyframes.

The source returns a coherent snapshot and its nonzero sequence through
`copyEqualizerLevels:count:sequence:`. The view updates targets only for a new
sequence; Core Animation supplies the motion between publications. A source that
stalls for 0.5 seconds causes one retarget to zero rather than holding stale music
forever.

## One fail-closed activity gate

An indicator may start its snapshot poller only when all five facts are true:

- the engine reports actual output audio;
- the platform says this row and surface are materially visible;
- the view is attached to a window;
- a level source exists;
- the view has nonempty drawable geometry.

Starting the poller declares one `equalizerLevelsWanted:YES`; stopping, replacement
and deallocation balance it with exactly one `NO`. Each shell counts consumers, and
the player installs the tap only while that count, output activity and the shell's
own visibility gate all agree. Thus every inactive state has no poller or FFT callback
to service. The audio-loss-only state can retain the finite compositor release above;
all pixel and ownership gate failures have no explicit level animation either.

Actual output is intentionally narrower than play intent. A file still Loading with
no outgoing sound is inactive. A tracked outgoing fade remains active until the
audio is really silent, even if a successor is Loading.

This is modeled liveness, not an invented tail clock. `AVAudioEngine` exposes no
reliable edge for a reverb or delay return becoming silent, so a wet FX tail after all
source nodes have stopped is not represented. The implementation deliberately does
not keep the analyzer awake for a guessed duration.

### macOS visibility

`MainPlayerController.syncEqualizerActivity` supplies output activity and window
occlusion. `PlaylistController` intersects the playing row with both the scroll clip
and window content and refreshes the result on scrolling and resizing. Compact mode
is covered by that real intersection: shrinking the window clips the playlist away,
without a separate `isPlaylistShown` approximation or any dependency on the UI timer.

### iOS visibility

The scene delegate supplies foreground-active state. The library combines its own
appearance with `willDisplayCell:` / `didEndDisplayingCell:`, scrolling and a real
table/window intersection. The root adds the selected tab and card exposure because
the card moves by transform over children that remain attached and "appeared."

The tab surface is live while an expand, minimize or interactive drag visibly exposes
it, then is inactive once the card settles fully over it. Interrupted and cancelled
card motion runs the same reconciliation. Switching tabs, scrolling the row away or
resigning scene activity stops both clocks.

## Analyzer

The tap is installed on the node that feeds the output:

- without the optional FX segment, `mainMixerNode` carries the post-fade,
  post-varispeed crossfade sum;
- with FX, `AudioFX.masterBusOutputNode` carries dry audio plus reverb and delay
  returns.

`installTapOnBus:` receives `format:nil` because this is a connected output bus. The
current output format supplies the initial analyzer configuration and a legal buffer
request; scratch is already fixed for the maximum supported FFT. The delivered
buffer's sample rate is authoritative and rebinds the analyzer without allocating,
discarding any partial window and normalization history tied to the old rate.

`AudioLevelMath.h` chooses the power-of-two FFT nearest 24 decisions per second,
bounded from 256 through 8192 frames. Five explicit bands cover 40–100, 100–250,
250–800, 800–4000 and 4000–20000 Hz, reserving three bars for bass and low mids. A
96 or 192 kHz route therefore does not add ultrasonic bars or multiply analysis
cadence. The larger high-rate windows still cost more arithmetic per decision:
192 kHz uses 8192 points, while 48 kHz uses 2048. FFT energy is normalized for
window size before the selected reference is applied. Each edge uses `ceil` to select
the first FFT bin whose center is at or above it. Adjacent half-open bands share that
exact bin boundary, so they neither admit a below-edge bin nor overlap one another.

The analyzer has two normalization modes:

- `SharedSpectrum`, the shipping default and debug token `spectrum`, integrates each
  band's power, divides by that band's octave span, averages the result over every
  complete window, then advances one strongest-band reference once for the callback's
  full analyzed duration and normalizes all five averages together. Heights therefore
  describe the callback-time average bass-to-treble balance against a common scale,
  not an instantaneous spectrum; octave compensation keeps the unequal ranges
  comparable.
- `RelativeActivity`, debug token `activity`, averages the bins in each band. For each
  complete window it advances five independent references and normalizes five levels,
  retaining each band's largest normalized level across the callback. Every spectral
  region remains expressive, but heights are relative to that band's own recent
  activity.

The activity mode is an A/B alternative, not a reconstruction of Apple's visualizer.
Apple does not publish its band boundaries or normalization, and this design does not
pretend to know them.

Left and right are transformed separately. Their magnitude-squared power is averaged
afterward, so opposite-polarity stereo has the same energy as in-phase stereo instead
of cancelling as a sample downmix would.

The callback's AVFoundation adapter reads the delivered buffer, then runs the analyzer
from preallocated storage with no allocation, locks or logging. It publishes all five
levels as one versioned snapshot. The lifetime-stable `AudioLevelPublisher` outlives
individual graph sessions. Removing or abandoning a session invalidates its snapshot;
an engine reset can never expose the old graph's levels through the new one.

Mode is fixed when a tap is created. Changing it through the debug command synchronously
removes and replaces an active tap, invalidating the old snapshot and starting with an
empty partial window and fresh references. If the tap is inactive, the next eligible
installation takes the selected mode. Graph replacement also starts fresh analyzer
history but retains the process-local selection; relaunch returns to `spectrum`.

## Runtime verification

Use the `vibe-debug` skill and `dump_equalizer`. Its nested
`audio.normalizationMode` is the canonical `activity` or `spectrum` string. Both debug
clients also expose `set_equalizer_mode activity|spectrum`; a successful reply carries
the same string plus `requested`, `tapObject` and `installed`, so a failed active-tap
replacement is visible immediately. A useful run checks both movement and quiescence:

1. While a differentiated test track plays with its row visible, snapshots advance,
   bands differ, one display link is active and `renderer.displayTicks` advances no
   faster than 30 per second. This counter measures snapshot polls, not displayed
   animation frames.
2. Pause or stop while the row remains visible. The bars release to dots, while the
   tap, poller and demand stop immediately. The transition may add one synchronous
   changed-bar model-write pass; during the compositor-only release, tap callbacks,
   analyzed windows, publications, display ticks and transform writes stay flat.
   Then scroll the row away, cover it, switch tabs, minimize or occlude the window,
   and background the iOS scene; those pixel-loss edges settle immediately, with all
   counters flat after the transition when no resize or cell population occurs.
3. Bring the same surface back while output continues. Both clocks restart without a
   stale pose or an unbalanced consumer.
4. Exercise a slow Loading request both with and without an audible outgoing fade.
   Only the latter remains active, and only until its fade ends.
5. A/B the same track and passage in both modes. A switch invalidates the old
   publication, so wait for `published:true` and a new sequence before judging the
   bands. Analyzer and renderer counters remain cumulative across the switch.

The exact counter homes are `audio.callbacks`, `audio.analyzedWindows`,
`audio.publications`, `renderer.displayTicks`, `renderer.geometryLayouts` and
`renderer.transformWrites`; every one is cumulative. With one active indicator and
stable bounds, `renderer.geometryLayouts` stays flat. `renderer.transformWrites`
counts model-target and immediate reconciliation writes, not displayed animation
frames: publication flow adds at most one per materially changed bar — no more than
five for each newly observed publication — while geometry, source or activity
reconciliation, an audio-stop release and one stale-to-zero settle can add one
changed-bar pass of their own. The release's displayed frames add no model writes.
Cell reuse can transiently overlap two pollers and consumers within the
main-thread handoff. Once that handoff unwinds, stable observable state permits one
active poller and the publication bound applies to it. After an inactive transition,
audio counters and `displayTicks` stay flat; geometry and transform writes require
stable bounds and cell population as well. Also expect `levelsEnabled:false`,
`audio.requested:false`, `audio.tapObject:false`, `audio.installed:false` and
`renderer.activeDisplayLinks:0`. `audio.outputAudioActive` records the queue-synchronized
producer fact as well. The top-level snapshot contains `published`,
`sequence` and `bands`; launch diagnosis is `silent`, `noAudioHw` and
`manualRendering`.

**`--silent` is not a reactive-EQ test.** It zeros `mainMixerNode.outputVolume`, and
the tap is intentionally downstream, so every band is legitimately zero. On macOS,
`--no-audio-hw` alone keeps the manual renderer and tap moving; it is suitable for
functional counter checks but not audible-start-latency measurements. On the iOS
simulator use `VIBE_AUDIBLE=1` when judging reactive motion. Never infer health from a
screenshot without checking the launch flags and `dump_equalizer` first.

## Tuning homes

| File | Owns |
| --- | --- |
| `Vibe/Audio/Levels/AudioLevelTap.{h,m}` | `AVAudioNode` installation/removal and one graph session's lifetime. |
| `Vibe/Audio/Levels/AudioLevelAnalyzer.{h,m}` | Preallocated FFT, chunking, stereo power and mode-specific callback aggregation. |
| `Vibe/Audio/Levels/AudioLevelPublisher.{h,m}` | Coherent player-lifetime snapshots, session validity and sequence. |
| `Vibe/Audio/Levels/AudioLevelPublisherInternal.h` | The tap's writer API; never a display dependency. |
| `Vibe/Audio/Levels/AudioLevelMath.h` | Analysis cadence, band edges, energy normalization and level mapping. |
| `Vibe/Controls/EqualizerAnimationMath.h` | Material-target threshold and explicit attack/release animation durations. |
| `Vibe/Controls/EqualizerActivityRules.h` | The renderer's fail-closed activity truth table. |

Keep those concerns separate. Changing the poll range or visible animation timing
must never raise FFT cadence, and changing audio normalization must never create an
app-side per-display-frame rendering loop.

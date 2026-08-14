# Dynamic UI update rate

Scale the playback-position timer's rate to the playhead's on-screen speed, so
short files and samples get a smooth waveform sweep while normal songs keep
today's 3 Hz cost.

## The problem

The playback UI is driven by a fixed-rate timer: `UPDATE_HZ 3` in
`Vibe/Main Window/MainPlayerController.m`, fired by `UIUpdateTimer`
(`Vibe/Util/UIUpdateTimer.{h,m}`, an occlusion-gated dispatch-source timer).
Each tick runs `updatePlaybackUI`, which pushes `position / duration` into
`AudioWaveformView.progress`; the Detailed renderer snaps the played-clip
layer's width with implicit animations deliberately disabled.

The playhead's on-screen speed is `waveformWidthPx × playbackRate / duration`
(position advances at `playbackRate` file-seconds per wall second; the fraction
is file-time over file-time duration). On a ~1200-device-pixel waveform:

- 4-minute song → ~5 px/s → under 2 px per 3 Hz tick → reads as smooth.
- 5-second sample → ~240 px/s → ~80 px per tick → three visible lurches per
  second.

Two existing pieces make raising the rate cheap:

- `AudioWaveformView.setProgress:` already gates repaints on the playhead
  crossing a **device pixel** (the `_progressTracker` bucket), so ticks that
  move the playhead less than a pixel cost almost nothing.
- The time labels in `TrackDisplayController.renderPosition:` are
  change-guarded at 1-second granularity (`round(displayPosition)` comparison,
  `setStringValueIfChanged`), so extra ticks don't redraw text.

So the timer rate can rise substantially without the per-tick work rising with
it — the expensive paths are already self-gating.

## Options considered

**A. Dynamically scale the timer rate — chosen.** Compute the Hz needed for
the playhead to advance ~2 px per tick, clamped to `[3, 30]`. One mechanism,
and it benefits both renderer families: Sonic Cirrus recolors discrete bar
layers on boundary crossings, so smoother progress there *requires* more
ticks — interpolation can't help it. The pixel gate keeps overshoot cheap. The
morph engine already runs a 60 Hz easing timer during morphs, so brief
higher-rate bursts fit the app's battery posture.

**B. Keep 3 Hz and Core-Animation-animate the playhead between ticks**
(retarget-from-presentation, like the download fill's `setLoadingProgress:`
easing). Best battery — the render server interpolates at full refresh with no
extra main-thread wakeups — but it only fits the Detailed family's clip-width
geometry; Sonic Cirrus can't interpolate and would stay choppy or need A
anyway. It also adds real subtlety: animating toward the last-known position
lags a tick behind; extrapolating ahead needs snap-downs on pause, seek, and
track end. Two mechanisms plus edge cases for a problem A solves in one.

**C. Display-link-driven progress while playing.** Maximally smooth, but
60–120 Hz main-thread wakeups for the entire duration of every track — against
the grain of the occlusion gating, the leeway rule, and the idle engine stop.
Overkill.

## Plan (option A)

### 1. `UIUpdateTimer` gains a settable rate

`Vibe/Util/UIUpdateTimer.{h,m}`: add a settable `hz` property that re-arms the
dispatch source in place with `dispatch_source_set_timer` — legal on both
active and suspended sources, takes effect immediately. Keep the
leeway-at-a-tenth-of-the-interval rule (the comment in the file explains why:
larger leeway lets the OS coalesce ticks and the time label visibly skips
seconds). No change to the wanted/windowVisible gating or the
suspend/resume/dealloc bookkeeping. No-op when set to the current value.

### 2. The desired-rate rule as a pure function

A small header-only function (so `Tests/` can compile it without the app
target — see `Tests/CLAUDE.md`), e.g. `VibeUIUpdateHzForPlayhead(widthPx,
duration, rate)`:

```
clamp(ceil(widthPx × rate / duration / kTargetPxPerTick), 3, 30)
```

with `kTargetPxPerTick ≈ 2`. Return the 3 Hz floor when `duration <= 0` (the
Loading gap, and the end-of-playlist park where the duration cache is zeroed).
Sanity anchors: a 4-minute track at 1200 px computes ~2.5 → floors at 3
(songs cost exactly what they cost today); a 5 s sample computes 120 → caps
at 30 (~8 px steps at 33 ms — motion, not lurching).

Unit-test the function: the floor, the cap, the duration-0 guard, the rate
term (pitch fader up → faster playhead → higher Hz), and a mid-range value.

### 3. `MainPlayerController` recomputes on input changes

A `syncUITimerRate` method reading the waveform view's width × backing scale
(`VibeBackingScaleForWindow`), the cached `_currentTrackDuration` (the live
player duration reads 0 in the Loading gap — same reason `updatePlaybackUI`
uses the cache), and `self.playbackRate`, then setting `_uiTimer.hz`. Call it
wherever any input changes:

- `didStartPlaying:` — the duration snapshot lands.
- The pitch/rate change path (`effectiveTempoDidChange`, or wherever
  `playbackRate` moves — the fader ticks funnel through there).
- `windowDidResize:` / `windowDidEndLiveResize:` — width changes. Rate
  re-arming is cheap, but skipping live-drag frames (as the title shrink-to-fit
  does) is fine too.
- `resumeUIUpdateTimer` — cheap catch-all on every resume.

Also worth a `LogDebug` of the chosen Hz on change, which makes verification
observable in the log stream.

### 4. Explicitly unchanged

- `setProgress:`'s device-pixel repaint gate and the label change guards —
  they are what make the higher rate cheap.
- Now Playing: it publishes from the `updateUI` funnel and the seek/pitch
  paths, not the tick, so 30 Hz will not spam the media daemon.
- The occlusion gating: a 30 Hz timer still stops entirely when the window is
  occluded or playback goes idle.

### 5. Verification

Via the vibe-debug skill: play a short generated file from
`Assets/test_audio_files/` (generate with `generate-test-audio.sh` if missing)
and confirm the playhead sweeps smoothly and the log shows the capped rate;
then a long track and confirm the timer rests at 3 Hz. Check both renderer
families (the waveform-style submenu), a pitch-fader move on a short file, and
a window resize mid-playback.

## Tunables

`kTargetPxPerTick` (~2 px) and the 30 Hz cap are the two knobs. Raising the
cap to 60 makes very short samples glassier at double the wakeup rate for
those files only. Start at 30 and judge by eye.

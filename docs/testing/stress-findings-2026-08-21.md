<!-- Point-in-time record of the 2026-08-21 overnight stress campaign.
     For a LATER run, the parts that stay useful:

     - Baselines (section D): resting views 47 / layers ~101 / engine nodes 23 /
       live heap 30-33 MB / all pending counters 0; in-flight live heap 32-64 MB
       while the footprint wanders hundreds of MB (allocator high-water, not
       retention).
     - Known-benign signals a future run WILL see again (section G):
       one TSan race report at AudioLevelTap _block_invoke+0x94 (the block-capture
       load; >1 report means look), TSan's own MetaMap::AllocBlock abort on long
       media-heavy soaks (instrumentation, not the app), and resting-views jumps
       whenever the Settings window has ever existed in the run (it is kept alive
       hidden and ui.views counts all windows).
     - Regressions to watch: the five fixes in section G, each with its repro. -->

# Overnight stress campaign — findings

Run 2026-08-21, macOS 26.5.2, Debug build, real audio hardware.
Corpora: the real 45 GB library (1,938 tracks), a 700-file synthetic cloud
corpus, a 42-file cloud-scenarios corpus, and a purpose-built hostile corpus.

---

## A. Confirmed bugs

### A1. Unbounded file-descriptor leak on every failed audio open (HIGH)

**One descriptor leaked per decode attempt against a non-empty file that
`ExtAudioFileOpenURL` refuses.** Linear and unbounded: 10 opens cost 10
descriptors, and 31 copies of a single file were held open simultaneously.
The 256-descriptor soft limit is reached after ~250 attempts.

Where: `Vibe/Audio/Waveform/AVFAudioWaveformLoader.mm`, `openFileAtPath:`.
The guard there covers only `url.isEmptyOrDirectory`.

The premise the guard rests on is stated in `Vibe/Util/Categories/NSURL+AudioOpen.m` and
is **wrong**:

> TRAP: AVAudioFile … leaks a file descriptor on every attempt against a path
> the kernel opens but a decoder finds nothing in: a zero-length file, or a
> directory. … **Merely unparseable content closes cleanly and needs no guard,
> so emptiness is the whole test.**

Measured, each arm from its own quiesced baseline, `file_cache` only (decode
path, UI untouched):

| input | leak |
| --- | --- |
| `enormous-id3-tag.mp3` — 4 KB, valid ID3v2 header announcing a 200 MB tag | **+10 per 10 opens** |
| `truncated-1.mp3` — first 8 KB of a real MP3 | **+10 per 10 opens** |
| `png-pretending.flac` — PNG magic, `.flac` extension | +2 per 10 opens |
| 20 zero-length `.flac` | 0 — the existing guard catches these |
| `text-pretending.mp3`, `random-bytes.wav`, `lying-riff-header.wav` | 0 |
| 10 well-formed files (control) | 0 |

So emptiness is *not* the whole test. What leaks is content the kernel opens
and `ExtAudioFileOpenURL` then rejects — which is precisely a partial download
or an interrupted rip, the common case in any Soulseek-style library.

`lsof` on the live process, after `quiesce`:

```
7r REG … /hostile-corpus/broken/enormous-id3-tag.mp3
4r REG … /hostile-corpus/broken/truncated-1.mp3
```

The unified log names the failing call:

```
AVAudioFile open failed for …/enormous-id3-tag.mp3:
  Error Domain=com.apple.coreaudio.avfaudio Code=2003334207
  UserInfo={failed call=ExtAudioFileOpenURL((__bridge CFURLRef)fileURL, &_extAudioFile)}
```

**Repro** (no harness needed):

```bash
V=build/DerivedData/Build/Products/Debug/Vibe.app/Contents/MacOS/Vibe
printf 'ID3\x04\x00\x00\x7f\x7f\x7f\x7f' > /tmp/bad.mp3; head -c 4096 /dev/urandom >> /tmp/bad.mp3
for i in $(seq 1 10); do "$V" --debug-cmd file_clear_cache /tmp/bad.mp3; "$V" --debug-cmd file_cache /tmp/bad.mp3; done
"$V" --debug-cmd quiesce; "$V" --debug-cmd dump_health | jq .process.fileDescriptors
```

**How it was found**: `--profile hammer` over the hostile corpus, resting fds
4 -> 57 across two post-`quiesce` samples, then 4 -> 313 in flight on a later
attempt. The fd oracle only detects this because it was rewritten to count
real descriptors rather than the descriptor table.

**Fixed**: `NSURL+AudioOpen` gained `failsAudioOpenPreflight`, which probes
with `AudioFileOpenWithCallbacks` over a descriptor the app owns and closes —
measured fd-neutral in both directions, with verdict parity against
`AudioFileOpenURL` on every format, because all three URL-based CoreAudio open
APIs leak identically (20 failed opens each cost exactly 20 descriptors), so
no URL-based preflight could work. All three guarded `AVAudioFile` open sites
switched to it. Verified on the rebuilt app: `enormous-id3-tag.mp3`,
`truncated-1.mp3` and `png-pretending.flac` all now +0 over 10 opens, on both
the open funnel and the decode path.

**Fix cost, measured** (50 warm iterations per file, best-of noted; the
preflight runs on every SUCCESSFUL open too):

| accepted file | size | mean |
| --- | --- | --- |
| WAV | 160 MB | 0.014 ms |
| MP3 | 21 MB | 0.024 ms |
| AIFF | 132 MB | 0.029 ms |
| FLAC | 65 MB | 0.039 ms |
| M4A with embedded art (worst case) | 2.4 MB | 0.67 ms |

Cost scales with header/tag complexity, not audio length — the M4A outlier is
the MP4 atom-tree walk, which `AVAudioFile` performs again immediately after,
so the preflight duplicates only the header-parse slice of an open. Against
the ~40 ms measured click-to-first-sound budget the worst case is ~1.7%, every
other format under 0.1%; against a multi-second waveform decode it is noise.
No macro start-latency change is measurable — the added work is bounded below
the measurement noise of the start-latency method itself.

### A2. The system Now Playing card can sit at Paused while the player plays

`--profile cloud`, 9,925 ops in, surviving a settle and a second sample (the
oracle drops anything that does not):

```
consistency — nowplaying.state_matches_player: card is 2, player is 1
```

`MPNowPlayingPlaybackState` 2 is Paused, 1 is Playing, so
`MPNowPlayingInfoCenter.defaultCenter.playbackState` was **Paused while the
player was playing**. Control Center, the media keys and any Bluetooth
transport read that card, so all three would show and behave as paused.

`dump_cloud_health` at the moment of capture had `cloudLaneHeld: 1` and
`cloudParsesPending: 1` — an open was in flight, which is where
`DebugConsistency.m` notes the publish resolves `isPaused` before `isPlaying`
"decided by the pending start intent".

**Only findable on real audio hardware.** `--no-audio-hw` suppresses the Now
Playing publish outright (`dump_now_playing` reports `hasInfo: 0` under it), so
every off-hardware run in this campaign scored this check against nothing.

**Reproduced independently.** It fired a second time under the TSan build on a
different seed — `tsan-cloud`, 7,832 ops in, identical violation. Two runs,
two builds, two seeds, same card-says-paused-player-says-playing. It is not a
one-off.

**The system-behaviour alternative is ruled out.** `build/probe-nowplaying.sh`
drove 19 deliberate transitions — settled toggles, toggles faster than a
publish can coalesce, toggles across track changes, and toggles inside a slow
cloud open — reading `dump_state` and `dump_now_playing` side by side at each
step. **0 mismatches**, and `check_consistency` clean at the end. The card
tracks faithfully for minutes, so the app does hold the active-media-app role
and its publishes land. Whatever produces the mismatch is rarer than any of
those transitions.

**Where it has to be.** `MainPlayerController+NowPlaying.m`'s
`updateNowPlaying` derives the state it publishes from exactly the inputs the
oracle checks against:

```objc
NowPlayingPlaybackState state =
    VibeNowPlayingStateForPlayer(self.audioPlayer.isPlaying, self.audioPlayer.isPaused);
```

So at publish time the two agree by construction. A persistent disagreement
therefore means the player reached Playing and **no publish followed**. Per
that file's own header comment, publishing is driven off `updateUI` "plus a
seek, a pitch-range change and the end of a fader gesture" — so any transition
into Playing that does not reach one of those four sites leaves the card stale
indefinitely. `NowPlayingController`'s coalescing early-out is not the cause
here: the function is simply never called.

The likeliest missing edge, and the one to instrument first: `didStartPlaying:`
is **dropped by the player when a newer play was submitted before it reached
main** (`AudioPlayer.submittedPlayIsCurrent:`, a documented guarantee). A
dropped `didStartPlaying:` means no `updateUI`, hence no republish — while the
player itself ends up playing. Both hits came from profiles that submit plays
faster than they settle (cloud, and cloud under TSan), which is exactly when
that drop fires.

Not proven — confirming it needs a log-instrumented repro that records every
publish beside every `didStartPlaying:` drop.

### A3. Crash: nil title reaches `setStringValue:` when the display state and
the display track disagree (HIGH)

A TSan hammer run over the hostile corpus died with an uncaught
`NSInvalidArgumentException`. Full stack, from the crash report:

```
VibeBurstJumps
  -[MainPlayerController(DebugPlayerSurface) debugPlayIndex:]
  -[PlaylistController play]
  __48-[MainPlayerController wireCollaboratorHandlers]_block_invoke.17
  -[MainPlayerController updateUI]
  -[MainPlayerController renderTrackPresentationForState:track:displayTrack:]
  -[TrackDisplayController renderState:track:duration:rate:errorStatus:]
  -[TrackDisplayController setTitleLabelText:]
  -[NSTextField setStringValue:]  ->  -[NSCell _objectValue:forString:errorDescription:]
  -[NSAssertionHandler handleFailureInMethod:...]  ->  objc_exception_throw  ->  terminate
```

**The value was nil, and it was nil because the TRACK was nil.**
`AudioTrack.title` never returns nil — it falls back to the filename and then
to `@""` — so a nil title can only come from messaging a nil track:
`[nil singleLineTitle]`. The artist label one line above survives the same
pass because it is handed the literal `@""`, which is exactly why the crash
lands on `setTitleLabelText:`.

Two places let it through, and either one alone would prevent the crash:

1. **`MainPlayerController.updateUI` derives the state and the track from
   separate reads.**

   ```objc
   TrackDisplayState state = [self displayState];              // reads currentTrack
   AudioTrack *track = self.playlistController.currentTrack;   // reads it again
   AudioTrack *displayTrack = [self displayedTrack];           // re-derives the state,
                                                               // then reads it a third time
   ```

   `displayedTrack` calls `[self displayState]` again and then returns
   `self.playlistController.currentTrack` as a fresh read. Nothing binds the
   state that was computed to the track that is returned, so `state` can say
   `Loading`/`Track` — both of which render the track — while `displayTrack`
   comes back nil. `VibeResolveTrackDisplayState` is careful to compare its
   track arguments "by identity only, never messaged"; `renderState:` then
   messages the one it is handed.

2. **`TrackDisplayController.setTitleLabelText:` has no nil guard.** Its
   early-out is `[text isEqualToString:self.titleTextField.stringValue]`, which
   on a nil `text` is a message to nil returning NO — so nil falls straight
   through to `self.titleTextField.stringValue = text`. `setStringValueIfChanged`
   has the same shape and would raise identically if ever handed a nil.

This is a sibling of the nil-metadata crash `vibe-stress` documents as its
worked example (`renderState` passing `track.metadata.fileInfoLine` into
`NSAttributedString`) — same method, different label, same root shape.

**Reproduced independently, and not a sanitizer artifact.** It hit twice:

| run | build | ops | stack |
| --- | --- | --- | --- |
| tsan-hammer-hostile | TSan | ~100 | identical |
| asan-hostile-extended | ASan+UBSan | 8,786 | identical |

Different builds, different seeds, same frames. A sanitizer only widens the
window; nothing in either stack belongs to the instrumentation.

Reached via the `burst` verb (hundreds of in-app index jumps at main-queue
rate) against a cold cache with the playlist being replaced underneath.
`build/probe-nil-title.sh` drives that shape deliberately; note that its crash
oracle must match on the `setTitleLabelText` signature rather than counting
Vibe crash reports, because TSan aborts inside `__tsan::finalize` on any
deliberate quit once it has reported a race, and that writes an ordinary-looking
Vibe crash report which a count-based test reads as a reproduction.

### A4. 20 data races on the equalizer's live level tap (HIGH)

TSan, hammer profile, real library. One report file, 20 races, every one of
them between the **audio render thread** and the **player's serial queue**
while the level tap is installed or replaced:

```
Read of size 8 by thread T814:
  __58-[AudioLevelTap initWithNode:publisher:normalizationMode:]_block_invoke
  AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform()      <- the render thread

Previous write of size 8 by thread T796:
  __copy_helper_block_e8_32s                                   <- block capture copy
  -[AudioPlayer applyLevelTapOnQueue]
  __32-[AudioPlayer setLevelsEnabled:]_block_invoke
```

The 20 summaries group into one bug at ~20 distinct field offsets of the same
object: `VibeAudioLevelAnalyzerConsume` (7), `…MeasureFrame` (9),
`…SetSampleRate` (1), and the tap block's own captures (4). So the analyzer's
state is being written by `VibeAudioLevelAnalyzerCreate` / `…SetSampleRate` on
the player queue while the render thread is inside `Consume` / `MeasureFrame`
of the tap that is being replaced.

Frame counts across all 20 reports:

```
40  -[AudioPlayer applyLevelTapOnQueue]
40  __32-[AudioPlayer setLevelsEnabled:]_block_invoke
35  -[AudioLevelTap initWithNode:publisher:normalizationMode:]
32  VibeAudioLevelAnalyzerCreate
21  VibeAudioLevelAnalyzerConsume
18  VibeAudioLevelAnalyzerMeasureFrame
10  VibeAudioLevelAnalyzerSetSampleRate
```

This is the seam `CLAUDE.md`'s equalizer guarantee describes — "one
demand-driven analyzer tapped at whichever node feeds the output …
`applyLevelTapOnQueue` picks" — and the races are on the *handover*, not the
steady state. A stale or torn pointer read on the audio render thread is the
worst place in the app for one.

Two things drive the handover hard in this campaign and both are new tonight:
the `equalizer_mode` op (`set_equalizer_mode` synchronously replaces an active
tap) and the equalizer's own demand-driven install/uninstall under a profile
that starts and stops audio constantly. Neither invents the race; they expose
it.

Report: `~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/tsan.61344`
(55 KB, 20 races). Triage with `build/triage-san.sh`.

### A5. Undefined behaviour: misaligned float load decoding every cached waveform

UBSan, ASan+UBSan build, hostile corpus:

```
Vibe/Audio/Waveform/AudioWaveform.mm:134:32: runtime error: load of misaligned
address 0x63100107c8a3 for type 'const float', which requires 4 byte alignment
  #0 -[CodableAudioWaveform initWithCoder:]
  #1 _decodeObjectBinary  ->  -[NSKeyedUnarchiver decodeObjectForKey:]
  #4 __35-[PINDiskCache defaultDeserializer]_block_invoke
  #7 -[AudioWaveformCache load:cacheKey:withLoader:claim:awaitPersist:completion:settled:]
```

The site is the NaN-validation loop in `initWithCoder:`:

```objc
const void *data = [coder decodeBytesForKey:@"chunks" returnedLength:&length];
…
const float *values = (const float *)data;
for (NSUInteger i = 0; i < numValues; i++) {
    if (!std::isfinite(values[i])) { return nil; }     // <- line 134
}
```

`decodeBytesForKey:returnedLength:` hands back a pointer **into the
unarchiver's own decode buffer**, at whatever offset the payload happens to
sit; it carries no alignment guarantee, and the reported address ends in `a3`.
Casting it to `const float *` and dereferencing is undefined whenever that
offset is not a multiple of 4.

The `AudioWaveform(numChunks, data)` constructor two lines below is **not**
affected — it `memcpy`s. Only the validation loop reads through a typed
pointer.

Why it matters despite working today: arm64 tolerates unaligned scalar loads,
so this is invisible at runtime. But the compiler is entitled to assume the
alignment it was promised, and a tight `isfinite` loop over ~16,000 floats is
exactly the shape that gets vectorised — and the paired/vector loads that
would replace it do fault on unaligned addresses. This runs on every cache hit
for every track, so a future toolchain or optimisation-level change turns it
into a crash on ordinary user data.

Fix shape is local: validate through a `memcpy` into an aligned float (which
compiles to the same scalar load on arm64) rather than a typed dereference.

**Reproduced**: two separate ASan runs, `asan.74721` and `asan.81538`, same
file, same line, different addresses (`…c8a3` and `…e08a3` — both ending in 3).

Reports: `~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/asan.74721`,
`asan.81538`.

---

## B. Investigated and dismissed

### B1. S10 "error and close settle clean" — NOT a bug; the scenario is fragile

`cloud-scenarios.py` S10 failed with `cloudLaneHeld: 1` two seconds after an
open that had to error. `build/probe-s10.sh` polls the hold every second
instead of sampling once, with the BPM/key analyzers both ways:

```
analyzers ON   t=0 held=1 claims=1 waiters=1 interactiveRunning=1
               t=1 held=1 backgroundRunning=1
               t=3 held=0 claims=0 waiters=0        -> cleared on its own
analyzers OFF  t=0 held=1 …
               t=2 held=0 claims=0 waiters=0        -> cleared on its own
```

Nothing is stranded: the claim and its waiter unwind by themselves, and
`quiesce` settles with every counter at zero both ways. The hold at t=2 is the
"slow" reading — a claim still legitimately in flight behind `capacity=1`.

**The one-second difference is the whole failure.** S10 samples at a fixed
t=2s; with the analyzers on the clear lands at t=3 and misses. The analyzers
are on because this campaign added them to the harness's `FEATURE_SETTINGS`
(a run inheriting them off silently skips the analyzer half of every decode),
so the scenario started failing on a harness change, not a code change.

Fix belongs in the scenario, not the app: poll for the hold to clear inside a
bounded window rather than sampling at a fixed instant — the same rule the file
already states for transfers ("assert on the trace, never on elapsed time").
Not changed here.

---

## C. Not bugs — measurements worth knowing

### C1. Sonic Cirrus now scales to 2,048 CALayers with window width

The uncommitted `WaveformUI` work makes bar count follow the drawn width.
Sonic Cirrus is the one style that spends **two CALayers per bar**, so a wide
window multiplies its layer count: measured 1,432 layers at a 2,844 pt window
(711 bars x 2 + chrome) and 1,189 at ~2,370 pt, against 256 before the change.
The `kMaxBarCount` 1,024 cap puts the ceiling at 2,048.

Not a leak — the count tracks width in both directions and returns to ~99 when
the style rolls to a Detailed variant.

**Measured, and the performance worry did not survive contact.**
`build/probe-cirrus-cost.sh`, playing a 20 MB WAV on real hardware, process CPU
from cumulative-CPU-time deltas over an 8 s window (not `ps %cpu`, which is a
decaying average since process start):

| style | width | layers | CPU |
| --- | --- | --- | --- |
| sonic_cirrus | 512 | 272 | 3.3% |
| sonic_cirrus | 1200 | 616 | 3.2% |
| sonic_cirrus | 2400 | 1216 | 3.1% |
| sonic_cirrus | 3600 | 1816 | 3.1% |
| detailed | 512 | 105 | 2.7% |
| detailed | 3600 | 105 | 3.0% |
| oversampling x4 | 512 | 105 | 2.6% |
| oversampling x4 | 3600 | 105 | 3.1% |
| sonic_cirrus (paused) | 512 | 272 | 1.1% |

6.7x the layers for no measurable CPU — flat, marginally lower if anything.
Core Animation carries them on the compositor, and the app-side waveform work
is ~2 points over idle whatever the style or width. So the design holds; this
entry stands as the measurement, not as an objection.

Caveats on the number: it is a Debug (-O0) build, it is process CPU rather
than GPU or compositor cost, and it says nothing about memory per layer or
about a machine driving several large displays.

### C2. The app correctly refuses the nasty paths

Symlink loop, directory named `.flac`, zero-length files, dangling m3u/cue,
emoji and unicode and quote and tab filenames, a cover that is a FIFO, a cover
that is a directory, 64 MB of JPEG-headed noise: all declined without a crash,
a hang or a wedge. Several of these ended runs only because my ops did not
tolerate a correct refusal.

---

## D. Clean results

Everything below ran on real audio hardware, audible, against the real library
unless stated.

| run | ops | result |
| --- | --- | --- |
| torture-local x2 | 19,200 | no violations, no growth, all pending counters clear |
| hammer-local (best attempt) | **55,904 in 42 min** | stopped only by the phase cap |
| artwork-local | 27,575 | clean to the full phase budget |
| torture-cloud x3 (fake provider, capacity 1) | 10,800 | clean, incl. the new resting cloud-health assertion |
| cloud-profile | ~10,000 | one A2 hit, then 577 s clean |
| tsan-ui | 15,238 | app oracles clean (races went to the report file) |
| cloud scenario suite | 22 scenarios | 21 pass, 1 = B1 |

Resting state after hammer-local, both post-`quiesce` samples: views 47,
layers 101-107, engine nodes 23, every pending counter 0, live heap 30-33 MB.
In-flight live heap held a 32-64 MB band across 15 samples while the footprint
wandered 177-873 MB — the allocator high-water behaviour the oracle discounts.

torture-cloud reached what the fuzz cloud profile struggles to: 468 cloud
parses pending with the lane held, at 250 ops/s of track changes against one
transfer slot, and everything unwound to zero at rest — claims 0, waiters 0,
`foregroundTransferActive` false.

### Not findings, checked and dismissed

- **`display.elapsed_time_placeholder` / `total_time_placeholder`** fired once
  in a torture seek burst. It is a render lagging a runloop turn, not a stuck
  state: torture.py was sampling `check_consistency` ONCE where stress.py
  settles and requires a second sample. With that discipline applied the whole
  seek phase ran clean.
- **`engine nodes 25 -> 42`** under TSan. `retiredFades` was 0 at every sample
  and the count swung both ways (25 -> 38 -> 25 -> 44), so it is attach churn
  during rapid track changes, not stranded crossfade pairs — the same 25-67
  no-trend swing the skill documents.
- **Layer growth to 1,432** — C1, the width-derived bar count, not a leak.
- **`_LSOpenURLsWithCompletionHandler() error -600`** killed tsan-ui's first
  attempt. LaunchServices refusing a launch straight after the previous phase
  killed the app; the retry ran 15,238 ops.

## E. Harness changes made tonight (uncommitted, for review)

Nothing in `Vibe/` was changed except one line: `windowAppearance` added to the
debug state dump, so the driver can put the user's appearance back after
flipping it. **No app code was touched in response to any finding.**

`.claude/skills/vibe-stress/scripts/stress.py`
- New op kinds: `block_main` (holds main, then runs a verb on the SAME turn —
  the only way to stage a worker callback arriving inside a user action),
  `audio_loading` (knob churn, ranges taken from
  `AudioLoadingConfiguration.m`'s validation rather than guessed),
  `equalizer_mode` (synchronous live-tap replacement — this is what exposed
  A4), `waveform_style` (renderer swap mid-morph), `appearance` (live
  light/dark flip, which re-resolves every waveform theme rule), `resize_storm`
  (several widths with nothing between them — which matters now that bar count
  follows width).
- New `hammer` profile: `loading`'s weights with the settle throttle off and
  the in-app `burst` verb enabled. This is what found A1 and A3.
- `.cue` added to `PLAYLIST_SUFFIXES` — the library has 32, and that whole
  sheet-reading path was never opened by any profile.
- BPM and key analysis added to `FEATURE_SETTINGS`: a run inheriting them off
  silently skips the analyzer half of every decode. (This is also what exposed
  B1.)
- `assert_running_binary`: stress.py never checked WHICH build `open -a`
  actually launched. Every Vibe shares one bundle ID, so a sanitizer run could
  report a clean pass over an uninstrumented binary with nothing saying so.
- Appearance and waveform style snapshotted at launch and restored at the end,
  so a run does not leave the app dark.
- `PATH_REFUSALS`: an open the app is RIGHT to refuse (symlink loop, zero-length
  file) is a tolerated error, not a finding. Without it the driver ends the run
  on the app behaving correctly.
- `--ignore-metric`: stands down an ALREADY-DIAGNOSED health metric so it stops
  masking what is behind it. Prints `RELAXED: not scoring …` in the header, so
  a relaxed run cannot read as a strict one. Needed because A1 was ending the
  ASan pass inside a minute.
- Layer growth limits re-sized for C1 (+800 -> +2400), with the arithmetic
  recorded — the old limit was right when every style had a fixed bar count in
  one shared mask path.

`.claude/skills/vibe-stress/scripts/torture.py`
- `--cloud`: arms the fake provider before opening the playlist, so every track
  change is a real transfer. The fuzz cloud profile cannot reach this shape —
  it has to settle to let a sweep run.
- `jump` phase: random `play_index`, including out-of-range and the
  same-row-twice case that only submission identity can drop.
- `blocked` phase: every op a held main thread with a verb chained on.
- A resting cloud-health assertion (claims, waiters, both lanes at zero).
- Settle-and-recheck on `check_consistency`, matching stress.py — a single
  sample at the end of a 40-op burst turns a render lag into a failure.

`.claude/skills/vibe-stress/scripts/run-torture.sh`
- Honours `VIBE_AUDIBLE` instead of hardcoding the off-hardware flags. (TRAP:
  macOS ships bash 3.2, where `set -u` treats an EMPTY array expansion as
  unbound — the audible case is the one with no flags.)

New: `make-hostile-corpus.py` — zero-length files, truncated rips, scrambled
frames, a lying RIFF header, an ID3 tag claiming 200 MB on a 4 KB file, a
directory named `.flac`, a symlink loop, dangling m3u/cue, emoji/unicode/quote/
tab filenames, covers that are empty, a directory, a FIFO, and 64 MB of noise —
with real tracks hard-linked in among them so track changes cross between good
and broken. Hard links, so it costs no disk and stays inside the sandbox grant.

Probes written for specific questions, all under `build/`: `probe-fds.sh`
(A1), `probe-nowplaying.sh` (A2), `probe-nil-title.sh` (A3),
`probe-cirrus-cost.sh` (C1), `probe-s10.sh` (B1).

Artifacts kept: `build/campaign/` holds every phase log, both TSan reports,
both UBSan reports, and both crash reports.

---

## F. Suggested order of attack

1. **A1** — a real user with a partial download hits it today, and the fix is
   local and testable (`probe-fds.sh` measures it directly).
2. **A3** — a crash, reproduced on two builds, and both halves of the fix are
   small: bind the state to the track it was derived from, and guard the label
   setters against nil.
3. **A4** — 41 races on the audio render thread. Not observed to misbehave, but
   it is the worst possible location for a torn read.
4. **A5** — one-line fix, currently harmless, becomes a crash on a toolchain
   change.
5. **A2** — needs the instrumented repro described above before it can be fixed
   with confidence.
6. **B1** — a scenario fix, not an app fix.


---

## G. Fixes and retest (same session)

Every A-finding and B1 was fixed and retested. **Nothing is committed** — the
diff is in the working tree for review. One line summary per fix, then the
retest results.

| finding | fix | where |
| --- | --- | --- |
| A1 fd leak | `failsAudioOpenPreflight`: probe via `AudioFileOpenWithCallbacks` over an fd the app owns and closes (all three URL-based CoreAudio opens leak identically, so no URL-based preflight can work); all three guarded `AVAudioFile` sites switched to it | `Util/Categories/NSURL+AudioOpen.{h,m}`, `AVFAudioWaveformLoader.mm`, `AudioFileMaterializationCoordinator.m`, `AudioFileConverter.m` |
| A2 stale Now Playing | reconcile from the UI tick: `updateNowPlaying` joins `updatePlaybackUI` in the timer, so a missed transition heals within one tick; the publisher's unchanged check makes it a comparison, not a republish | `MainPlayerController.m` |
| A3 nil-title crash | both halves: state and track now derive from ONE `currentTrack` snapshot (`displayStateForTrack:` / `displayedTrackForState:track:`, used by `updateUI` and `updateNowPlaying`), and both label setters map nil to `@""` | `MainPlayerController.m`, `+NowPlaying.m`, `MainPlayerControllerInternal.h`, `TrackDisplayController.m` |
| A4 level-tap races | an `_Atomic` armed gate in the tap session: release-store after `installTapOnBus:` returns, acquire-load at callback entry — one happens-before edge covering the analyzer creation, every session field, and the block copy | `AudioLevelTap.m` |
| A5 misaligned load | validate the decoded floats through `memcpy` into an aligned local instead of a typed dereference of the unarchiver's buffer | `AudioWaveform.mm` |
| B1 fragile scenario | S10 polls for the hold to clear inside a 20 s window instead of sampling at t=2 s | `cloud-scenarios.py` |

Gates after the fixes: mac Debug build, iOS build, `make check-layout`,
`make check-vocabulary`, `make test`, and `make analyze CONFIG=Release` —
all clean.

Retest results:

| retest | result |
| --- | --- |
| A1: hammer over the hostile corpus, fd oracle strict | **PASSED 31,232 ops** (pre-fix: failed every attempt inside a minute, fds to 313); direct probe: every leaking file now +0 over 10 opens, fds 7-18 for the whole 23-minute run |
| A1 performance | preflight costs 10-40 µs per accepted open (160 MB WAV: 14 µs); M4A worst case 0.67 ms — ≤1.7% of the ~40 ms click-to-sound budget, <0.1% for every other format |
| A2: cloud profile, same check armed | **PASSED 13,741 ops**, zero `nowplaying` violations (original hits at 9,925 and 7,832) |
| A3: 60-round targeted probe | no crash (note: this probe never reproduced the crash on a plain build even pre-fix; the sanitizer hammers below are the stronger evidence, and neither crashed in Vibe code) |
| A4: TSan hammer + ui, 34k+ ops total | **20 races → 1**, and the survivor is the structural floor: the block's own captured-pointer load at `_block_invoke+0x94`, which must execute before any app-side ordering can — the copy-vs-invoke shape inherent to every `installTapOnBus:` block anywhere. Every race inside the session (analyzer fields, Consume, MeasureFrame, SetSampleRate) is gone |
| A5: ASan+UBSan over the hostile corpus | **0 reports** (pre-fix: fired within minutes on every run) |
| B1: full scenario suite | **PASS=22 of 22**, S10 included, with the analyzers on — the exact condition that broke it |

Two retest failures are NOT app findings, on inspection:

- `tsan-hammer` "crash" at 26,769 ops: TSan's own metadata allocator dying
  (`__tsan::MetaMap::AllocBlock` → `Die`) under a VideoToolbox allocation —
  the same instrumentation failure as the overnight run, media-heavy soaks
  exhaust TSan's shadow metadata.
- `tsan-ui` "resting views grew 47 → 223": the Settings window ("Playback"
  pane, 176 views) was open at rest. A clean-state replay of the exact op
  slice does NOT open it, and the journal shows no settings-opening op — the
  denylist held. The mechanism that matters for the harness: once the
  Settings window has EXISTED in a run, `settings_close`/close hides it but
  `AppDelegate.settingsWindowController` keeps it alive, and `dump_health`'s
  `ui.views` counts all windows visible or not — so its ~176-229 views join
  the resting count permanently and the tight resting-views limit fires.
  How it became visible mid-run is unresolved (macOS window restoration from
  an earlier dirty kill is the leading suspect — my bisect instance inherited
  exactly such a restored "Appearance" window at launch); it did not recur in
  replay and no op in the fuzzer's vocabulary opens it. Left open.

### What remains open

1. The A4 residual: one benign-by-analysis race report at the block-capture
   load. Closing it would need a capture-free global block over a static
   atomic session slot — possible, but it trades a provably-app-clean report
   for real structural constraints. Recommend living with it and reading any
   future TSan report count as "> 1 means look".
2. The A2 root cause: the reconcile prevents the stuck card, but the missing
   edge (most likely a dropped `didStartPlaying:`) was never caught in the
   act. The symptom is structurally gone either way.
3. The tsan-ui settings-window appearance, above — a harness/oracle question,
   not an app defect.

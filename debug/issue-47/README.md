# Issue #47: the AirPulse A300 delay — investigation notes

A handoff for a fresh look. Everything the reporter sent is in this folder, the whole public thread is `thread.md`, and this file is what the maintainers (Chris and Claude) did, found, fixed, and still don't understand, as of 2026-09-21 ~13:30 UTC. Beta6 carries the launch-race fix (`34002782`), the instant-looking quit (`bca6e9fa`) and the beta instrumentation (`b47042e3`); beta7 adds callback, recovery and render-stall logging. See "Reading beta6 and beta7 logs".

**The second review's five findings are fixed, and all four recommended diagnostic additions are implemented.** See the latest fix pass below and [the second review](review-2-2026-09-21.md) for the original reproductions. The four cases now live in the regular audio suite; git history retains the deleted duplicate probe patch.

**Then read "Post-review fixes and next-beta test", "Where it stands" and "What is still unexplained".** The rest is evidence and history.

---


## Beta8 signal attribution across track changes

The previous probe could mistake a buffered outgoing tone for the new track's first signal and report zero leading silence. Capture now uses the node's player-to-render clock mapping and buffer timestamps, blocks until outgoing fades actually retire (including volume settling), and excludes the last hardware render block conservatively. Gapless promotion arms a capture at the new file's boundary. Every `Signal:` summary names the file after track publication; per-arm chatter and empty superseded summaries are removed.

The excluded prefix is explicitly unmeasured: `observationStartMS` says where inspection began, `observedLeadingSilenceMS` counts only inspected silent frames, and `firstSignalAfterStartMS` locates the observed threshold crossing relative to the start. A late tap, long crossfade or FX tail still prevents this post-mix probe from being an isolated file-silence measurement.

Validation: 53 audio tests pass, including 300/700/1500 ms quiet intros replacing a loud tone, bit-perfect/ordinary paths, 44.1/48 kHz output, 10/500 ms fades, a gapless boundary and idle-engine restart. Six targeted Thread Sanitizer tests pass. Live manual rendering found first signal at 300.9/700.9/1500.9 ms with correct filenames; a muted hardware run retained timestamped partial captures. Both live checks passed all 29 consistency checks. Debug macOS/iOS builds, Release analysis on both targets, a Release build with beta logging disabled, and layout/vocabulary/strings/translations checks pass. The A300-specific lag still needs reporter testing.

Complexity: +180 net lines, zero new files/types. Reuses the existing fade-completion path and tap, replaces unfiltered capture with timestamp filtering, and removes redundant start/supersession logs.

## Beta8 signal-capture follow-up

The signal probe now checks every 100 ms and logs as soon as the first above-threshold buffer arrives. It stops scanning samples after that buffer. The tap completes partial captures before removal, abandonment or replacement, retaining the original play/segment and start reason; stale polls cannot complete a new request. A terminal snapshot survives removal. Without a threshold crossing, observed silence is a lower bound over captured frames; a late tap still cannot reconstruct the file's beginning. The missing `HAL:` and `Preflight:` documentation is restored in the Devices and Util owners.

Validation: 50 audio tests and four targeted Thread Sanitizer tests pass, including early completion, partial capture retention, empty captures, replacement identity and unchanged PCM. Debug macOS/iOS builds, a Release build with beta logging disabled, Release static analysis on both targets, and layout/vocabulary/strings/translations checks pass. Live off-hardware signal captures completed in 100–106 ms. A muted real-HAL session produced eight summaries for eight armed captures: six interrupted captures retained 300–400 ms of observed silence and two expired normally. Both live checks passed all 29 consistency checks. Physical A300 acceptance remains outstanding.

Complexity: +126 net lines, zero new files/types; capture completion is consolidated in the tap lifecycle, replacing the delayed discard-on-removal/supersession path.

## Beta8 instrumentation refinement

Signal capture is automatic in beta builds, with observed leading silence reported from the existing post-mix tap. Keep the playing row visible. The UI event waits for a position beyond the published baseline. First-render logs retain the fresh-clock, unity-rate host-time estimate alongside the poll observation; resumed clocks explicitly omit the estimate and use the retained pause position to detect new progress. Exclusive default-follow retries produce one attempt-count/last-status summary. Quit detaches the delegate once, on main. Duplicate logging guidance and the two superseded probe patches are removed; tests and git history retain the reproductions.

Validation: 49 audio tests and three targeted Thread Sanitizer tests pass, including automatic capture of a known 250 ms silent opening and unchanged-PCM checks. Debug macOS and iOS builds pass, Release static analysis is clean on both targets, and layout/vocabulary/strings/translations checks pass. A silent real-HAL run with no signal flag produced automatic bounded capture, 57–59 ms start/seek estimates, 34–57 ms first advancing UI updates, a resumed-clock unavailable estimate with valid progress, and 29 passing consistency checks. Polling observes rendered buffers, which can be timestamped ahead, so its result is not simply the host estimate plus a polling delay. Physical A300 acceptance remains outstanding; no beta was cut.

Complexity: −309 net lines, zero new files/types; removed two duplicate probe patches, the redundant quit assignment and repeated logging documentation. The HAL write remains one implementation shared by individually logged binds and summarized retries.

---

## Second-review fixes and diagnostics

Failure resets now defer re-adoption until an enclosing mutation's rollback has completed, without retrying an already-failed saved lookup. Natural end captures its submission before recovery. Device-loss parking and paused idle shutdown share segment retirement and rescheduling, preserving a resumable track rather than sending a false finish. Carried modes remain readable until main-thread persistence completes. The render baseline skips invalid clocks and manual rendering.

New diagnostics:

- Paired `Phase:` begin/end records cover exclusive setup/acquire/release, default-follow settlement, device pin, output preparation/format confirmation, engine start and node play. Missing ends identify calls that have not returned; failures retain their OSStatus/error context and deadlines are explicit. Default-follow pin retries are summarized once with attempt count and last OSStatus.
- `Timeline:` joins seek/resume admission, scheduling, callback decisions/delivery and the first advancing UI position. `Callback:` includes captured/current segment identity. This separates queue delay from a delayed display update.
- Save Debug Info collects persisted logs independently of fresh hardware/player snapshots. Each optional section has a two-second deadline and one outstanding worker; `freshDiagnostics` labels cached/unavailable results and includes timestamps. The debug verb is asynchronous too. `block_player 8` verifies repeated exports while the queue cannot respond.
- Beta logging automatically measures the existing post-mix tap for up to three seconds per start/seek/resume, with no launch argument. Keep the playing row's equalizer visible and active. `Signal:` records observed leading silence in milliseconds, first above−60 dBFS sample/host time, peak/RMS and nonfinite count; absent/removed taps and superseded captures are explicit. Late installation can miss the beginning, and fades/FX affect these output samples. No extra file open, permanent tap, audio-thread allocation, lock or log; this measures software signal, not physical output.

Validation of the initial implementation: **1,408 unit tests + 36 cloud-runner tests; 48 audio tests**, including the four reproduced regressions, positive signal/unchanged-PCM comparisons, silent bounded capture and re-arming. The final audio run emitted zero invalid-node-time assertions. Debug and universal Release macOS builds, the iOS simulator build and a Release build with `VIBE_VERBOSE_LOGGING=0` pass; Release static analysis is clean on both platforms. Layout, vocabulary, string and translation checks pass. Three targeted Thread Sanitizer tests pass without race reports; the first run exposed a test-setup race when replacing the injected mode provider, fixed by settling the setup queue before returning. Debug teardown also retires the player before stopping, so it cannot enqueue saved-device adoption after shutdown.

Live off-hardware verification: a visible equalizer supplied a 127,890-frame capture at 44.1 kHz, peak 0.36615, finite RMS 0.15991 and zero nonfinite samples. Hidden/no-demand taps reported unavailable. An eight-second player-queue block did not prevent Save Debug Info: repeated exports covered both cached and initially unavailable player sections, followed by fresh snapshots after recovery. The original first UI update logged 1.3 ms after publication (this did not establish movement; the current log waits for advancement); all 29 consistency checks passed. These validate diagnostic behavior, not physical output latency.

Transient local logs and result bundles are not retained evidence. Reproduce with `make test`, `make test-audio`, the builds/checks above, and the live protocol below. The A300-specific delay still requires a symptom-marked reporter run.

Complexity: +685 net lines including tests/docs, +420 production lines, zero new files/types. Device-loss and idle shutdown now share retained-track rescheduling; seek completion delivery is consolidated in one method. Additional lines principally implement diagnostics and regression coverage in their existing owners.

---

## Post-review fixes and next-beta test

The 2026-09-21 review reproduced five gaps in the production player. They were committed in `ca9124c9`: one guarded saved-device resolver prevents recursive HAL retries; pending identity survives repeated fallback notifications and an absent launch device; destination mode preferences win on model matching; only an actual automatic carry is persisted; and termination retires transport, pending opens and recovery before restoring the device. See `review-2026-09-21.md` for the original reproductions. The original probe patch is retained in git history; the cases now live in the regular suite.

Diagnostics for the next beta:

- `Timeline: play N` joins submission, player-queue admission, open settlement and the segment's the host-clock estimate of first render and first **observed render progress**. Poll observation includes scheduling delay and must not be compared directly with beta7's 47–58 ms estimates. First-progress polling uses a monotonic three-second deadline and stops when the segment is superseded. The presentation latency is a reported estimate. Neither proves when the DAC becomes audible.
- The old background reopen/leading-silence probe is removed. Logging no longer starts extra file reads outside loading admission.
- Both queues and the output clock log stall **onset and recovery**, including an invalid/missing render clock. Main-thread stall stacks remain enabled; keep both architectures' matching dSYMs when the beta is cut.
- Bare **M**, including the physical key under Greek input, records track, position, loading/playing state, input delay and the current output report. Key repeat emits no extra marks; text editing and modified shortcuts still pass through.
- Save Debug Info now includes pending device identity, requested/bound IDs, applied modes, hog/restore obligations, engine state, graph rates and submission/segment identity. This uses the same queue snapshot as the debug channel. Verbose logging remains enabled in Release via `VIBE_VERBOSE_LOGGING=1`.

Tester protocol (send with the next beta, not yet posted):

1. Select the A300 explicitly in Vibe. Keep the playing row and its equalizer visible for the automatic signal probe. Keep Bit-perfect on. Use the same two or three files for both runs, including a track with an obvious opening sound. Note whether the A300 is also macOS's default output.
2. With Exclusive **off**, change tracks and seek several times. Press M once if lag occurs. Save Debug Info before quitting, labeled "exclusive-off".
3. With Exclusive **on**, repeat those exact tracks/actions. Press M once at each perceived lag while the player window has focus. Note whether the counter, the whole window, or only the sound was delayed. Save Debug Info before quitting, labeled "exclusive-on". A short screen-and-sound recording is useful if the render timing remains short during marked audible delay.
4. Separately try launch with the A300 off, then power it on while stopped/paused; and power it off/on after a successful bind. Check that Vibe remembers the device and its modes. Choosing System Output deliberately must cancel that pending return.
5. If Darkside still fails, provide that exact audio file if shareable; its padding cause remains unverified from logs alone.

Validation of this fix pass: **1,408 unit tests + 36 cloud-runner tests; 43 audio tests**, including all five reproduced failures and delayed-discovery/manual-selection coverage. Debug and universal Release macOS builds and the iOS simulator build pass; Release static analysis is clean on both platforms; layout, vocabulary, string extraction and translation checks pass. The final audio suite and Release build were repeated after consolidation. A silent real-HAL run on the built-in speakers with Greek UI recorded first observed render progression at 56.0/41.2/47.4 ms for start/seek/change, two deliberate M markers and no repeat marker, all new report fields, zero consistency violations, and clean termination. These are local diagnostic checks, not A300 acceptance.

Historical change size: **+186 net lines** including tests/docs, **−99 production lines**, **zero new files/types**. Consolidation removed the duplicate resolver branch, transient fallback state, standalone saved-request comparison, separate active-device queue read, and the unbounded diagnostic file reopen.

Release handoff: source version remains 1.13-beta7/build 119 until the next release is cut. Use the repository's `vibe-release` workflow for the version bump, signed/notarized beta and dSYM preservation. No release or issue comment was published by this fix pass.

---

## Where it stands

- **The original freeze is fixed.** On 1.12 and the first two betas, track starts and seeks froze the app for 1–2 s. Two `sample`s showed why: every bit-perfect status change during playback made the Settings window re-solve Auto Layout for all six panes, on the main thread, inside a resize animation, even with Settings closed. Fixed in beta3; the leftover per-change cost fixed in beta5. See "Bugs fixed", items 1 and 2.
- **The device-forgetting is fixed.** Switching the DAC off made Vibe drop the chosen device and its bit-perfect/exclusive modes. Fixed in beta4 (#61).
- **One symptom remains.** With **Bit-perfect output and Exclusive output both on**, the reporter still perceives a delay of roughly 1–2 s on track changes ("the delay is still there and makes the player freeze for some seconds too"). It is **instant** with Exclusive off (bit-perfect still on), instant with bit-perfect off, and instant with the A300 set by hand to the same 44.1 kHz 24-bit format in shared mode. Everything we measured through beta5 is identical between Exclusive on and off — but his c42 answer shows those measurements stopped short: **the time counter does not move during the lag**, so either the engine is not rendering or the main thread is not redrawing, and neither was measured until beta6. Details in "What is still unexplained".
- **Two smaller things he reported last:** quitting is slower with bit-perfect on (understood; now looks instant, `bca6e9fa`, not yet in a beta), and "when I scroll my playlist and change the track feels laggy" (not yet investigated).
- **A small real bug found in his files:** launching with Exclusive on races the output unit following macOS's default, CoreAudio answers `'nope'`, and the bit-perfect status reads "switch failed" for the whole session. Fixed in `34002782` (not yet in a beta), but **not reproduced locally**: the built-in speakers switch too fast to collide.
- **His c42 answers:** (1) "time counter not start at the delay lag after that yes" — the counter is frozen through the lag; (2) the delay **still happens** with the Mac Studio speakers as the macOS output and the A300 chosen in Vibe with Exclusive on — so it is exclusive access itself, not the A300 losing its default role. He also repeats that bit-perfect should output 16-bit; see "About 16-bit".
- **His beta7 file (c44)** contains 26 node-render timing entries at 47–58 ms and no USER MARK. This does not establish audible output timing or whether a measured start coincided with perceived lag. The Darkside preflight rejection is separate; the hinted-open fix handles a reproduced padding case, but the actual file is still needed to verify that cause.
- **Next:** beta8 with the post-review fixes and diagnostics below. The remaining A300 lag still needs a symptom-correlated recording.

---

## The reporter's setup

From his debug-info reports (`attachments/c39-*`, `c40-*`) and the thread:

| | |
|---|---|
| Mac | Mac Studio M2 Max (`Mac14,13`), 32 GB, Apple Silicon, not translated |
| macOS | 27.0 (26A428), **Greek UI** (app language `el`) |
| DAC | **AirPulse A300** active speakers (Edifier-made; clock source "EDIFIER Internal Clock"), **USB**, built-in DAC, no auto-standby |
| A300 formats | 44.1 / 48 / 96 / 192 kHz × i16 / i24, 2 ch. Its own default: **48 kHz i16**. Buffer 512 frames (range 14–4096), declared output latency 13 frames, safety offset 13 frames, stream latency 0 |
| System output | **The A300 is his macOS default output.** Other outputs: LG TV (HDMI), Mac Studio speakers ("Ηχεία Mac Studio", device 90) |
| Inputs | **None** — a Mac Studio has no microphone, so macOS has no default input device |
| Library | 320 kbps 44.1 kHz MP3s ("16-bit"), so every track is the same rate |
| Other players | Audirvana: bit-perfect and exclusive both work, nothing else audible. He also reported (c3) that with Swinsian in hog mode and Vibe playing, both were audible from the same device |

When Vibe takes exclusive access (the HAL's "hog mode") of the A300, macOS moves the system default to the Mac Studio speakers (device 90). With Exclusive off the default stays on the A300 (device 96).

---

## Timeline

Times are UTC. "c7" is the 7th comment in `thread.md`.

| When | What happened | What it established |
|---|---|---|
| 09-20 06:13 | Report on **1.12**: delays on track change "and in general" on the "System Output (AirPulse A300)" row; none when choosing "AirPulse A300" directly; switching the DAC off forgets the settings. Screenshot also shows `CADefaultDeviceAggregate-2343-3` in the Output list | Three problems: the delay, the forgetting, a private aggregate leaking into the list (#48) |
| c2–c6 | First theory: USB speakers sleeping, macOS moving the default, Vibe reconnecting twice. He answered: all music is 44.1 kHz, music never stops, Audirvana's exclusive works, **the freeze also happens on seeks**, and only while Vibe is open | Seeking never touches the device, so reconnection alone cannot be it. Vibe measured 0.16 s track change / 0.26 s seek on our hardware |
| c7 (1.12 log) | His `log stream` showed one **5.9 s** device rebind after the A300 vanished and came back as a different device id | A real slow path (#53), but he confirmed the freeze is ~1–2 s and not tied to that |
| c12 → **beta1** | Built to time the device path; only steps over 1 s were recorded | He got nothing (c14) — ambiguous: no slow steps, or no logging? Cost a round trip |
| c15 → **beta2** | Records every open, seek, start and rebind | His log (c16): every step under 0.13 s; no freezes captured in the log at all |
| c18 → samples | `sample Vibe 30` during freezes: `c19`, `c21` (beta2) | **Found it**: main-thread Settings re-layout storms triggered by audio events (see Bugs fixed #1). Seek freezes were worst because drag-seeking produces fades → status changes → re-layouts on the thread tracking the mouse |
| **beta3** | Settings storm fix, width floor, listener-latch fix | |
| c26 | "with bitperfect off the app didn't have any issues" | Consistent with the storm, which only fires when the bit-perfect status changes |
| c28–c29 (beta3 sample) | "the delay is still there and makes the player freeze for some seconds too" | The sample shows no multi-second stall on any Vibe thread. Longest main-thread items: 1.3 s refused drag slide-back (his gesture), 0.9 s first Settings open, 0.36 s one full-pane re-solve after a status change. Player queue busy 294 ms total in 14.6 s |
| **beta4** | #61 re-adopt, #63 liveness, caller diagnostic | |
| c32 (beta4 log stream) | Track changes every ~1 s with bit-perfect on: open 0.001–0.003 s, node start ≤ 0.011 s, no device format change between tracks. At relaunch: `could not set output device 96 (OSStatus 1852797029)` (`'nope'`) | Vibe hands audio over within ~20 ms. The `'nope'` is the launch race (below) |
| c33–c35 | "using default device is instant that means bit perfect off". Screenshot of Audio MIDI Setup: A300 held by Vibe (lock icon), 24-bit integer 44.1 kHz, "its lock it at 24bit — bitperfect needs to be at 16bit like other players do" | His theory: the 24-bit format. (Vibe gives lossy files 24-bit by design — `VibeBitPerfectChooseFormat`, `kVibeBitPerfectAssumedLosslessDepth`) |
| c36–c37 | Isolation tests: bit-perfect off + A300 set to 24/44.1, then 16/44.1 by hand → **both instant**. Bit-perfect on + Exclusive **off** → **instant** | **Not the bit depth. The delay needs Exclusive output.** He still asks for source-matched depth |
| **beta5** | Save Debug Info (one file: settings, devices, player, this run's log), every log level kept | |
| c39–c40 | Three debug-info files: `1rst` (Exclusive on), `2nd` (Exclusive off), `the lag` (Exclusive on, "much lag"). Plus: slow quit with bit-perfect, laggy scroll + track change | Analysed below: Mac-side identical per track |
| c41 | Our two questions (time counter; Mac Studio speakers as default) | |
| c42 | "time counter not start at the delay lag after that yes"; "still happening yes" with the speakers as default; bit-perfect should be 16-bit | The counter is frozen through the lag (held rendering, or a main-thread stall). Exclusive access itself is the trigger, not the default moving |
| **beta6** | Launch-race fix, instant-looking quit, beta instrumentation (`Timeline:`, `HAL:`, `Stall:`, `USER MARK`) | Published, never announced: beta7 followed |
| **beta7** | Adds `Callback:` for every system callback Vibe registers, `Recovery:` verdicts, the output render-stall watch, and system HAL events | |
| c44 | beta7 debug info; "the delay now stops the player itself"; screenshots: Swinsian holding the A300 at 16-bit, Vibe showing "could not open Darkside" at 24-bit | No Mac-side delay; the stop was the preflight refusing Darkside.mp3 (fixed, `a0661167`). No USER MARKs |

---

## What is still unexplained: the Exclusive-only delay

### What the reporter observes

With Bit-perfect **and** Exclusive output on, changing tracks feels delayed by ~1–2 s, and he describes the player "freezing". It does not happen with Exclusive off, with bit-perfect off, or in shared mode at the identical format. It still happens when the A300 is not the macOS default output (c42).

**The time counter does not move during the lag** (c42). The counter shows `AudioPlayer.position`, which is derived from the frames the engine has rendered, but it is drawn by a main-thread UI timer. So a frozen counter means one of two things, and they need different fixes: **the engine is not rendering** (playback genuinely held), or **the main thread is not redrawing** (a UI freeze while audio may be fine). Beta6's `Timeline:` line measures the first and its `Stall:` line the second.

### Everything the Mac shows is identical between Exclusive on and off

1. **Vibe's own timings** (beta4 log stream `c32`, beta5 reports): file open 0.001–0.005 s, node start 0.000–0.012 s, the engine already running at every change (`start — engine 0.000s`). **Caveat, learned from c42: "node start" is only `[node play]` returning, not the first rendered frame.** Through beta5 nothing measured rendering on his machine. No device-format change between tracks: all his files are 44.1 kHz, so the format is set once (44.1 kHz i24, ~180–240 ms on the A300) and left alone.
2. **The A300's HAL description** (beta5 reports): buffer 512, declared latency 13, safety offset 13, stream latency 0, physical 44.1 kHz i24, virtual 44.1 kHz f32, same clock — **identical** with Exclusive on and off. Only the exclusive owner and the system default differ.
3. **CoreAudio's own log per track change** (`tools/pertrack.py` over `2nd` vs `the lag`): every change in both modes shows exactly the same set — MP3 decoder and converter creation plus two harmless errors. No AUHAL device selection, no IO stop/start, no `setPlayState` change, no aggregate rebuild per track.
4. **Local reproduction attempt** on an Audient iD4 (not the system output) at 44.1 kHz i24 with MP3s: time until the playhead actually advances after a track change, 8 changes each (`tools/trackdelay.py`): **95 ms median with Exclusive on, 95 ms with it off**. That number is mostly the debug channel's own round trip. This *does* measure rendering (the position), so on the iD4 exclusive access does not hold rendering back. Beta6's probe measures the same thing on his A300: about 55 ms from node start to first rendered frame on the built-in speakers.

### What *does* differ with Exclusive on

- Vibe owns the A300's hog; macOS moves the **system default to the Mac Studio speakers**.
- At the moment exclusive is taken (engine start from stopped), AVAudioEngine's output unit **follows the default** to the speakers and Vibe pins it back (`settleOutputUnitAfterHoggingSystemDefaultOnQueue:`). Visible in `the lag` at 14:35:17: `default=90`, AUHAL `SelectDevice` 96→90 then 90→96, engine restart, ~0.15 s total. This is **once**, not per track.
- At launch with Exclusive on, that pin can collide with the follow and fail with `'nope'` (see Bugs found, not yet fixed).

### Hypotheses, none confirmed

1. **The A300 itself behaves differently when hogged** — firmware/driver buffering or muting at stream changes, invisible to the Mac. Weakened by: no IO restart happens per track, so the device sees one continuous stream in both modes. Would explain everything the Mac shows being equal.
2. ~~**It is tied to the A300 not being the system default while hogged**, not to hog as such.~~ **Ruled out by c42**: it still happens with the Mac Studio speakers as the default. The rest of this entry is kept for the record. Worth thinking about what else changes when the default moves: system sounds and other apps go to the speakers; macOS 27's `as_client`/`SessionCore_macOS_Legacy` logs ("Allow Smart Routing on macOS", `setPlayState ... Output {A300}`) show an AVAudioSession-like layer on macOS tracking which output Vibe plays to — does it treat a session on a non-default, hogged device differently?
3. **The "freeze" is partly UI, not audio.** Still open after c42: a frozen counter fits a main-thread stall as well as held rendering. He also reports laggy scrolling + track changes. With the Settings storm fixed, something else may cost main-thread time per track change; exclusive mode could make it worse (e.g., main-thread HAL calls such as `refreshBitPerfectRows` → `supportsHogModeForDeviceID:` per report change). His beta3 sample showed nothing like seconds, though. Beta6's `Stall:` lines settle it.
4. **The launch race leaves a broken unit.** In `1rst` the unit ended bound to the A300 but the report stayed "switch failed", possibly with the unit's formats still the speakers' (a hidden rate conversion). But `the lag` (Exclusive enabled while running, no `'nope'`, format confirmed) still lagged, so this cannot be the whole story.

### Ideas for the next data

- **Beta6 logs** (see "Reading beta6 logs"): does `Timeline: first audio out` stay near 55 ms after node play with Exclusive on, or jump to the lag? Are there `Stall:` lines for the main thread at the `USER MARK`s? Does any `HAL:` event on the A300 (running, format, overload) coincide with track changes?
- A `sample` taken **during** the lag with Exclusive on, and a second with it off, to compare main-thread and IO-thread time (his beta3 sample predates the storm fix and had Settings open).
- Reproduce with a DAC that is the macOS system output, Exclusive on, and listen as well as measure. (Chris's iD4 as system output was the next local step.)
- An audible-start measurement independent of the playhead: loopback or a physical recording, since the playhead only proves the engine is rendering.

---

## What his beta7 file showed (c44)

`attachments/c44-*-Vibe-Debug-Info-beta7.txt`, 62 s into a beta7 run with Exclusive on:

- **Every track change was fast.** 30+ changes: click → play request 1–5 ms; first frame rendered 47–58 ms after node play, 60–90 ms after the click. Many of his MP3s open with near-silence (Sorry.mp3 711 ms, Hit That Switch 333 ms, Drowning 310 ms), which adds to what he hears in any mode.
- **The A300 ran continuously.** `HAL:` shows Vibe owning it from 16:47:00 to 16:47:49, `running = 1` throughout, no format change, no overload, no abnormal stop, no other process taking it. No output render stall, no player-queue stall during playback.
- **"The delay now stops the player" was a different bug.** At 16:47:43 he clicked Darkside.mp3 and `failsAudioOpenPreflight` refused it before `AVAudioFile` saw it; Vibe shows the error and does not auto-skip, and 6 s later the engine idle-stopped and released the A300. Cause, reproduced here: the preflight sniffed content with no type hint, which refuses an MP3 with undeclared bytes between its ID3 tag and first frame; the real open plays it. Fixed in `a0661167` with a regression test.
- **Three main-thread stalls** (345, 655, 284 ms) came after playback had stopped, just before the save — most likely opening Settings and the save panel. Beta8 captures stacks for these.
- **No `USER MARK`s**, so whether he heard a lag during this run is unknown.
- His screenshots again compare Swinsian's 16-bit hold with Vibe's 24-bit; see "About 16-bit".

## About 16-bit

**From beta9, lossy sources prefer 16-bit output** in `VibeBitPerfectChooseFormat`, as the reporter asked. If the device does not offer 16-bit at the selected rate with enough channels, the existing wider-integer and floating-point fallbacks apply. Lossless files still use their source depth; ALAC/FLAC with unspecified depth retain the 24-bit assumption.

Earlier betas preferred 24-bit for MP3s to reduce rounding of the decoder's floating-point output. MP3 has no native PCM bit depth, even when encoded from a 16-bit CD; neither output choice restores the discarded source information. The A300 offers integer 16 and 24. The reporter's c37 test had instant playback at 24-bit without Exclusive, so that observation alone did not implicate bit depth in the delay.

## Reading beta6 and beta7 logs

Beta6 and beta7 (`VIBE_VERBOSE_LOGGING`) add these lines to every debug-info file; beta7 adds the `Callback:`, `Recovery:`, render-stall and `HAL: system` lines. All times are milliseconds.

| Line | Meaning |
|---|---|
| `Timeline: play of X requested N ms after its input event (click\|key\|media key)` | Main-thread lag between his input and the play reaching the player. Only logged for input that can start a play |
| `Timeline: first audio out N ms after node play, M ms after the play was requested; X opens with S ms of near-silence, so sound at the output T ms after the request; output presentation latency L ms` | When the new node's first frame actually rendered, from its own render clock. ~55 ms after node play is normal here. **A lag in rendering shows as a large N** |
| `Timeline: no audio rendered 3 s after node play` | The engine never rendered the new node within 3 s |
| `HAL: <device> (<id>) <property> = <value>` | Any change on any output device: running, running somewhere, nominal rate, physical/virtual format, exclusive owner, buffer, latency, safety offset, clock source, `IO overload: a cycle was dropped`, volume, mute, streams, data source. Also `watching`, `is gone`, and `macOS default output is now …` |
| `Stall: the main thread\|player queue could not run anything for N ms` | That queue was blocked for N ms (reported when over 200 ms). A main-thread stall freezes the time counter without touching audio |
| `USER MARK n` | He pressed M — the moment he heard the lag |
| `Stall stack: the main thread, N ms in: frame \| frame \| …` | **beta8.** Where the main thread was stuck, captured once per stall. System frames are named; Vibe's print as `Vibe +0x…` offsets — symbolicate with `dsyms/<version>/` (`atos -arch arm64 -o dsyms/<v>/Vibe.app.dSYM/Contents/Resources/DWARF/Vibe -l 0x100000000 0x1<offset>`) |
| `Preflight: CoreAudio refused X as its extension's type (…) and by content (…); N bytes, starting with …` | **beta8.** Why a file was refused before opening |
| `Stall: the audio output rendered nothing for N ms while playing` (or `…until playback or the engine stopped`) | **beta7.** The output's own render clock stopped while playing: the device's IO stopped pulling audio. Checked every 50 ms |
| `Callback: …` | **beta7.** A system callback Vibe registers fired: `HAL default output changed` / `device list changed`, `output unit current device changed; bound to device N`, `bit-perfect device listener, '<fourcc>' changed`, `AVAudioEngine configuration changed`, `segment completed (track end \| gapless handover \| stale, superseded)`, `remote command <name>`, `the Mac is going to sleep` / `woke` |
| `Recovery: <verdict> (engine …, node …, requested N, bound N, unit at device rate yes\|NO, state N)` | **beta7.** What each engine recovery saw and decided: `idle on the requested device`, `graph healthy`, `paused with the graph intact` (all "nothing to do"), or `rebinding to device N` |
| `HAL: system coreaudiod restarted` / `alert sound output is now device N`, and `HAL: <device> IO stopped abnormally` | **beta7.** System-level HAL events |

**How the three places a lag can live show up:** the output render clock stalls (`Stall: the audio output…`) → the device's IO isn't running; IO runs but `Timeline: first audio out` is large → the new track isn't being played into a running output; a `Stall: the main thread…` at the `USER MARK` → only the window froze.

## Bugs fixed during this investigation

In order of how much they mattered to #47. Commits are on `main` in `cmicali/vibe`.

1. **Settings re-solved every pane on audio events — the original freeze.** `c40f5b0d` (+ docs `6e59fce5`), shipped in beta3. Chain: `publishBitPerfectReportOnQueue` → main → `audioPlayerDidChangeBitPerfectReport:` → `SettingsGeneralViewController.refreshBitPerfectRows` → `SettingsPaneViewController.paneContentDidChange` → `runAnimationGroup { remeasurePanes → applySharedSizeToPanes → naturalPaneSize (fittingSize) }` for every pane. It also ran with Settings closed, so one visit taxed the rest of the process. Fix: a hidden window does nothing; a visible one measures itself first and stops when its own size did not move.
2. **A caption reported a text change as a layout change.** `fd856eea`, beta5. After #1, each bit-perfect status change still cost a layout pass plus one pane solve (measured: 6 of 6 play/pause flips on the old build, 0 of 8 on the new). `SettingsRowView.setCaption:` now answers whether the row's height changed, measured on the one label. A first attempt reserved caption height for the tallest status; dropped when measurement showed no bit-perfect caption wraps in any of the 30 languages at the narrowest window (widest: Dutch, 549 of 552 pt).
3. **Vibe forgot a device that was switched off.** #61 (`d5016865`), beta4. A vanished device and a deliberate System Output pick both committed `-1` and cleared the saved preference. Now a vanish keeps the choice and the device is re-adopted, with its modes, when it returns (in session when not audibly playing, and across relaunch). A USB interface on another port is recognised by `kAudioDevicePropertyModelUID` (the device UID embeds the USB location).
4. **A rebind could fire onto a device as it vanished.** #62/#63 (`d510849e`), beta4. Recovery trusted a device-list snapshot that lags an unplug; it now also asks the device (`kAudioDevicePropertyDeviceIsAlive`, `kAudioHardwareBadObjectError`). Caller diagnostic for failed rebinds: `7eb48855`.
5. **Output-listener latch forced a graph rebuild on every later bind.** #56 first half (`4fee19ce`), beta3. The listener-removal obligation never retired for a vanished device.
6. **Vibe's private aggregate showed in the Output list.** #48 (`65e513c1`), before beta1 — the `CADefaultDeviceAggregate-2343-3` row in his first screenshot.
7. **System Output row got its own bit-perfect caption** (`4d24332f`) — "choose a wired device" had been shown to someone whose system output is a wired DAC.
8. **Settings width floor** (#60, `24f787eb`) and **autohiding scrollers** (`b9eddbc7`).
9. **Instrumentation** (none of it a fix, all of it needed): slow-bind logging (#54 `2bc04386`), phased rebind timing (#55 `222e28ef`), every open/seek/start/rebind recorded (`be3c50c4`, `c52e128b`), debug-channel command/reply logging (`0e303170`), and in beta5 `VIBE_VERBOSE_LOGGING` (every log level persisted) plus **Save Debug Info** (`794d2a7d`).
10. **Release tooling**: prerelease support and `ARGS` forwarding in `make github-release` (`70fc5592`, `24c92f53`) — without the latter the first beta nearly published as the site's Latest.

## Bugs found, not yet fixed

- **Launch race with Exclusive on (in his `1rst` and beta4 log).** *Fixed after writing: `34002782`.* Taking exclusive access of the system-output device makes macOS move the default; AUHAL's `CADefaultDeviceAggregate` follow selects the speakers; Vibe's pin back lands while that `SelectDevice` is finishing and fails with `'nope'` (`kAudioHardwareIllegalOperationError`) after creating the A300's IO proc but before updating stream formats. AVAudioEngine then posts a configuration change, and `recoverEngineConfigurationOnQueue` calls the graph healthy (running, node present, unit names the A300) and does nothing. The report stays "switch failed" all session. **Fix (`34002782`, unreproduced here):** bit-perfect health also requires the unit's hardware format at the device's rate, so that notification triggers a clean rebind, and the report now logs *which* confirmation failed (`bit-perfect: format not confirmed, because …`).
- **Slow quit with bit-perfect.** `AudioPlayer.prepareForTermination` synchronously restores the device format (the A300 takes ~180–240 ms; the wait is bounded at 1.5 s), releases the hog, and stops the engine. *Fixed after writing: `bca6e9fa`* — `applicationShouldTerminate:` now hides the windows, Dock tile and menu bar first and finishes off main (windows gone ~90 ms after the quit instead of at exit).
- Open issues found along the way: #53 (a slow bind blocks the player queue), #56 second half (one field carries two meanings), #57 (the "current device" can read stale on some hardware), #58 (release script never checks the commit), #59 (hide Dock icon request).

## Investigated and ruled out

| Theory | Ruled out by |
|---|---|
| Sample-rate adjustment between tracks | All his files are 44.1 kHz; no format change between tracks in any log |
| Speakers sleeping and reconnecting | No auto-standby; the freeze also happened on seeks, which never touch the device |
| The A300 not supporting exclusive access | Audirvana's exclusive works; Vibe's report shows Vibe owning the hog |
| Vibe's audio path being slow | Every open/start under 0.013 s (beta2, beta4, beta5 logs) |
| A multi-second main-thread stall in beta3+ | beta3 sample: nothing over ~1 s, and that was a user drag and the first Settings open |
| The 24-bit format | 24/44.1 instant in shared mode; bit-perfect (24-bit) instant with Exclusive off |
| The device running with different buffer/latency when hogged | Identical HAL properties in both modes |
| Per-track device reconfiguration in exclusive mode | Identical CoreAudio activity per track in both modes |
| CoreAudio "Could not find default device" / "no object with given ID 0" | Same rate in both modes (~5.5 per track); caused by AVAudioEngine's aggregate finding **no default input device** on a Mac Studio |

---

## Code map

| Where | What |
|---|---|
| `Vibe/Audio/Mac/Devices/AudioPlayer+Devices.m` | Everything device- and bit-perfect-side. `acquireExclusiveOutputOnQueue` / `releaseExclusiveOutputOnQueue` (hog), `settleOutputUnitAfterHoggingSystemDefaultOnQueue:` (the follow-and-pin, with its TRAP comment), `recoverEngineConfigurationOnQueue` (engine configuration change → health check → rebuild), `publishBitPerfectReportOnQueue` (the status the header and Settings show), `prepareForTermination` (quit) |
| `Vibe/Audio/AudioPlayer+Engine.m` | `startEngineAndPlayNode:` — exclusive is taken only when the engine starts from stopped |
| `Vibe/Audio/Mac/Devices/OutputFormatRules.h` | `VibeBitPerfectChooseFormat` (lossy sources take 24-bit), `VibeBitPerfectFold` (report → status), `VibeCanBindSavedOutputDevice` |
| `Vibe/Audio/Mac/Devices/CoreAudioUtil.m` | HAL reads/writes; `setHogOwnedByThisProcess:` (hog writes toggle — it reads first); `diagnosticDescriptionOfDeviceID:` |
| `Vibe/Mac/Settings/` | The Settings panes; the storm lived in `SettingsPaneViewController.paneContentDidChange` and `SettingsFormViews.setCaption:` |
| `Vibe/Mac/App/DebugInfo.m` | Save Debug Info's report builder |
| `Vibe/Audio/Mac/Devices/CLAUDE.md`, `Vibe/Mac/Settings/CLAUDE.md` | The subsystem docs, including every trap met here |

---

## Files in this folder

| File | What it is |
|---|---|
| `thread.md` | The whole public thread of #47, verbatim, oldest first. Includes his pasted logs: c7 (1.12 `log stream`), c16 (beta2 `log show | grep AudioPlayer`) |
| `thread.json` | The same, raw from `gh issue view 47` |
| `attachments/body-*.png` | His first screenshot: Settings > Audio on 1.12 with the System Output row, the direct A300 row, and the leaked aggregate |
| `attachments/c19-*`, `c21-*` | `sample Vibe 30` on **beta2** during freezes — where the Settings storm was found |
| `attachments/c28-*` | `sample Vibe` on **beta3** (14.6 s, 1 ms interval) — no multi-second stall on any Vibe thread. Symbols: rebuild `v1.13-beta3` from the tag; the layout matches (UUID will not) |
| `attachments/c32-*` | `log stream --level debug` on **beta4**, bit-perfect on, many track changes, then System Output, then back, then a relaunch with the `'nope'` |
| `attachments/c35-*.png` | Audio MIDI Setup: A300 held by Vibe at 24-bit 44.1 kHz, his note about 16-bit |
| `attachments/c39-*-1rst.txt` | beta5 Save Debug Info, **Exclusive on** (launched that way: `'nope'`, status "switch failed") |
| `attachments/c39-*-2nd.txt` | beta5 Save Debug Info, **Exclusive off** |
| `attachments/c40-*-the-lag.txt` | beta5 Save Debug Info, **Exclusive on**, "much lag" (Exclusive switched on while running at 14:35:17) |
| `dsyms/<version>/` | Each beta's dSYM (arm64 and x86_64), kept because `make release` overwrites the archive, to symbolicate `Stall stack:` offsets |
| `attachments/c44-*` | His beta7 debug info and two screenshots (Swinsian at 16-bit; Vibe's "could not open Darkside" with the A300 at 24-bit) |
| `tools/pertrack.py` | Lists the CoreAudio messages seen in the second after each track change, across a report's log: `python3 tools/pertrack.py a.log b.log` (the log is the part of a report after `=== Log`) |
| `tools/trackdelay.py` | Measures, through the debug channel of a running **Debug** build, how long after each track change the playhead starts moving |

A debug-info report is state as pretty JSON, then `=== Log, this run: N lines ===`, then log lines as `HH:mm:ss.SSS <level> [<source>] message`, where level is `N` notice/default, `I` info, `E` error, and so on; `[app]` is Vibe's own. Under beta5's `VIBE_VERBOSE_LOGGING`, Vibe's info and debug lines are written at default level, so they all appear as `N`.

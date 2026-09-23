---
name: vibe-stress
description: Stress, soak, fuzz, and torture the running Vibe app against a folder of real audio files — seeded random controller actions without pointer input, with consistency, leak, hang, and crash oracles, a single-playlist skip/seek torture suite for the delivery races that only open when transport outruns the metadata scan, a deterministic cloud-loading scenario suite over a fake file provider (download ordering, the foreground hold, the open deadline), plus the sanitizer (ASan/UBSan/TSan) and malloc-debug build matrix. Use for soak or endurance runs, memory-leak and resource-growth hunting, race hunting, fuzzing the file-loading path, hammering skips and seeks on a large playlist, testing cloud/placeholder loading order, or minimizing a failing run to a repro.
---

# Stress and fuzz testing Vibe

**Read the `vibe-debug` skill first.** Everything here rides its `--debug-cmd` channel and launches through its `launch.sh`, so its traps — grant rules, off-hardware flags, two-instance raciness, stale-binary check — all apply and are not restated. The oracle verbs (`dump_health`, `check_consistency`, `quiesce`, `dump_cloud_trace`) are ordinary channel commands in its command list.

Needs a **Debug** build; the channel compiles out of Release. Flags: each script's `--help` is authoritative and is not restated here.

Three drivers, three questions:

- **`stress.py`** randomizes controller actions for hours and notices when something breaks. Every profile is command-only: no raw mouse events, keyboard events or per-operation activation.
- **`torture.py`** loads one large playlist and hammers transport so track changes outrun everything async.
- **`cloud-scenarios.py`** drives one named situation and asserts what the fake provider's trace must contain — the cloud guarantees are about *order*, which random driving cannot state.
- **`device-flap.py`** makes the output device disappear and return, hundreds of times, and asserts playback survived — a named guarantee random driving cannot state either, and one deliberately kept out of the stress profiles.
- **`bitperfect-soak.py`** plays a mixed-rate corpus at SETTLE pace and asserts the mode reaches Active on every track, drives the device to that file's own rate, holds exclusive access, and restores the device's format at the end.

**Unattended stress must leave desktop input alone.** `Channel` allows only reviewed controller/delegate commands and a small set of app-only menu identifiers. It rejects raw `click`, `drag`, `mouse_*`, `key*`, arbitrary `script` wrappers and unknown verbs, including inside nested `block_main` calls. Single commands, batches, journals, replay and shrink all use this gate. An old journal containing input is rejected before replay/shrink launches the app; do not silently filter it and claim the same reproduction. There is no flag that unlocks random input. Launching Vibe and explicitly changing its window size still affect its presentation.

**Never recover a stress failure with global input.** Do not use `input.swift`, Accessibility mouse driving, AppleScript/System Events, or computer-use clicks to unstick or extend an unattended run. Capture diagnostics and stop the run. App-local NSEvents are not containment: artwork and playlist handlers can start native file-export drags, and the waveform/background can start native window dragging. Keeping endpoints inside the window or repeatedly activating Vibe does not prevent these effects.

## Running each suite

**Stress.** Every run is reproducible: the seed prints first, `--seed N` regenerates the identical op sequence, every op is journaled as NDJSON under `build/stress/`, and `--replay` re-runs a journal verbatim. Without the seed a fuzz failure is nearly worthless.

```bash
make stress CORPUS=~/Music/big
make stress CORPUS=~/Music/big ARGS="--profile loading --duration 3600 --iterations 100000"
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --seed 48213    # replay exactly
```

Profiles (`--profile`): `base`, `loading`, `hammer`, `ui`, `cloud`, `theme`, `playlist`, `artwork` — what each weights and why is `references/profiles.md`. `cloud` and `artwork` need purpose-built corpora (`make-cloud-corpus.py`, `make-hostile-corpus.py`; same file).

By default, validated batches travel through one `script -` invocation. `--no-batch` uses one client per operation when individual timing matters. Raw script commands from journals are refused; only the runner constructs the batch after validating every command and checking that arguments can be represented without changing token boundaries.

**Torture.** One playlist, no settle anywhere, ops batched through `script -` so a burst is one client invocation (~15 real track changes/s). Phases per `--phases` (default `skip,seek,mixed,jump,blocked,boundary`; `references/profiles.md`). Between bursts: alive, `check_consistency`, fds / engine nodes / live heap / views against baseline; at the end a `quiesce` that requires every `pending` counter at zero.

```bash
make torture PLAYLIST=~/Music/big                      # APP= defaults to the Debug build
make torture PLAYLIST=~/Music/big ARGS="--rounds 40 --burst 40 --seed N"
```

**Run it through `run-torture.sh`, never `torture.py` by hand.** Three things must be true before a result means anything and the wrapper asserts each: exactly one mac instance is up, it is the binary you intended, and the caches are cold. **Cold caches are the point, not hygiene**: the delivery races only open while a scan is in flight as playback starts, so a warm 6400-op pass has proven far less than it looks.

**Cloud scenarios.** One fresh app launch per scenario; budget several minutes. Run `make check-cloud-scenarios` (the runner's trace-helper tests, also part of `make test`) first.

```bash
.claude/skills/vibe-stress/scripts/make-cloud-corpus.py --out build/cloud-scenarios-corpus --folders 3 --per-folder 14
.claude/skills/vibe-stress/scripts/cloud-scenarios.py --corpus build/cloud-scenarios-corpus
.claude/skills/vibe-stress/scripts/cloud-scenarios.py --corpus <dir> --only S4b,S7 --verbose
```

The first two corpus folders must each hold 6–40 playable files; larger folders outlive a scenario's bounds or rotate its finite trace. Clean report is **`PASS=24 XFAIL=1`** (S9), no `FAIL`/`ERROR`. `XFAIL` does not fail the run; `XPASS`, `FAIL` and `ERROR` do, and an `XPASS` is a finding to investigate — the gap closed or the scenario stopped reaching it. The scenario rules, the registry and the `block_main` instrument are `references/cloud-scenarios.md`.

**Device flap.** One question: does playback survive the output device going away and coming back? `--mode vanish` builds a *public* aggregate over a real device, makes it the system default and destroys it, so the default device genuinely ceases to exist — what a USB DAC does when it sleeps. `--mode move` only reassigns the default between two devices that both persist, a strictly weaker stimulus kept to separate "the default moved" from "the device vanished". Oracles per flap: playback state and position, `check_consistency`, the app alive; `dump_health` against a min-of-first-three baseline every `--health-every`; a closing `quiesce` requiring every `pending` counter at zero.

```bash
.claude/skills/vibe-stress/scripts/device-flap.py --corpus ~/Music/big --device 87 --flaps 300
.claude/skills/vibe-stress/scripts/device-flap.py --corpus ~/Music/big --device 87 --device-b 111 --mode move
```

`--device` is an `AudioDeviceID`, which **changes whenever the device re-enumerates** — read it fresh, never from a note. The Swift helper beside the script is rebuilt on demand.

**TRAP: this moves audio for every app on the machine, not just Vibe** — which is why device changes are excluded from the stress profiles rather than added as a profile, and why this is run deliberately rather than left soaking unattended. It restores the original default on every exit path including SIGINT/SIGTERM, but a SIGKILL leaves the default moved and may strand a public aggregate.

**Rotating real devices, when the question is what a bind COSTS.** The helper's `rotate` mode cycles the system default across a list of real devices in one process, creating nothing. Measured with Vibe on System Output over 42 changes, playback unbroken:

| Destination | median settle | max |
| --- | --- | --- |
| RME Fireface 802 (USB, 30ch) | 0.525 s | 0.533 s |
| Audient iD4 (USB, 4ch) | 0.314 s | 0.352 s |
| FiiO USB DAC-E10 (USB, 2ch) | 0.127 s | 0.131 s |
| Built-in speakers | 0.086 s | 0.394 s |

**Bind cost does not track device quality** — the RME is 4x slower than the cheap FiiO, consistently. Do not assume a better interface binds faster.

**TRAP: Vibe must be on System Output for a rotation to test anything.** An explicitly bound device does not follow the default, so rotating it produces zero rebinds while looking like a successful run. Verify `dump_state.player.outputDevice` is null before believing a result; a first attempt at the table above was invalid for exactly this.

**TRAP: a clean run does not clear the hardware path.** A destroyed software aggregate returns in microseconds; a real DAC waking from sleep takes seconds to become usable, and that latency is where the delay in #47 lives. This driver proves Vibe's own rebind path survives — measured flat across 300 flaps — and nothing about a physical device. Only power-cycling real hardware tests that, and it cannot be automated.

**Bit-perfect and exclusive output.** `bitperfect-soak.py` is the only suite that exercises them. Per track, at settle pace, it asserts: status Active, the device running at **that file's** rate (read from `afinfo`, never from the app — asserting the app against itself proves nothing), all three graph rates equal, no varispeed in the chain, `rateExact`/`formatConfirmed`/`channelsMatch`/`depthOK` all true, and the hog held on the chosen device. Then a mode toggle must return to Active and release the hog, and the device's nominal rate must be back where it started — read from the HAL, since the app's own report of what it restored is the thing under test.

```bash
.claude/skills/vibe-stress/scripts/bitperfect-soak.py --corpus Assets/test_audio_files/rates \
    --device 110 --device-name "Fireface 802 (24240711)" --rounds 2
```

**TRAP: torture.py cannot test either mode, and passes anyway.** Torture runs at 10–70 ops/s; a bit-perfect format switch needs about a second to confirm. Under torture the switch never completes before the next track change, so the mode sits in `switchFailed` for the whole run — and since exclusive only acquires once bit-perfect confirms, **hog is never taken at all**. Measured: a 720-op run with both settings enabled reported `PASSED, no violations` having exercised neither. Same class as the folder-art trap: a disabled feature looks exactly like a clean run.

**TRAP: the System Output row embeds the default device's name**, so `--device-name "Fireface 802 (24240711)"` matches `System Output (Fireface 802 (24240711))` first. That row is the -1 policy and is never eligible, so the mode refuses to arm and the run dies looking like a device fault. The matcher excludes System Output rows and prefers an exact match; keep it that way.

**A rate the hardware lacks is not a failure.** The driver reads `kAudioDevicePropertyAvailableNominalSampleRates` and requires `rateUnsupported` for those tracks instead of Active. Measured: the FiiO USB DAC-E10 offers 32/44.1/48/96 kHz and no 88.2, so an 88.2 kHz file must report `rateUnsupported` on it and Active on an RME Fireface, which has it. Without that check a device limitation reads as a bug.

**Sanitizer matrix.** Three builds catch disjoint classes; **TSan matters most** because the threading contract (engine mutations on the player queue, non-blocking getters, delegate callbacks on main) is invisible to every other oracle.

```bash
# TSan: separate derived data so the plain Debug build stays usable
C=~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp
xcodebuild -project Vibe.xcodeproj -scheme Vibe -configuration Debug \
    -derivedDataPath build/DerivedData-tsan -enableThreadSanitizer YES build
launchctl setenv TSAN_OPTIONS \
    "log_path=$C/tsan:halt_on_error=0:external_symbolizer_path=:symbolize=1:history_size=7"
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big \
    --app "$PWD/build/DerivedData-tsan/Build/Products/Debug/Vibe.app" --profile artwork --max-stalls 20
launchctl unsetenv TSAN_OPTIONS        # session-wide until unset
```

`-enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES` is a second build (incompatible with TSan; ~3x slower; aim it at malformed files, where input reaches TagLib's C++). Reports land as `$C/tsan.<pid>`; **no file means no race**. The container-path and symbolizer rules, the malloc-debug variants and `--client-app` are `references/sanitizers.md`.

## Named gesture tests, separate from stress

Only use these when the gesture itself is under test, on a **dedicated test Mac or disposable macOS VM**, with a Debug app already running. The flag asserts that isolation exists; it does not create it. A different Space on the user's desktop is not isolation. Do not provision a VM or run global input as an automatic fallback.

```bash
.claude/skills/vibe-stress/scripts/stress.py --gesture-test pitch-reset --isolated-desktop
.claude/skills/vibe-stress/scripts/stress.py --gesture-test pitch-drag --isolated-desktop
```

These are bounded tests of the named pitch fader. They prepare its pitch, resolve and hit-test fresh geometry inside the app immediately before queuing a complete gesture, and require the player and fader to reach the expected result. They restore the starting pitch and panel visibility even on failure. An unavailable, clipped or covered target fails instead of trying coordinates elsewhere. They cannot combine with replay or shrinking and do not enable arbitrary input. Keyboard routing, hover, drag thresholds, autoscroll, external drag-out and OS focus remain dedicated gesture/OS tests under `vibe-debug`'s [OS-input reference](../vibe-debug/references/os-input.md); normal stress makes no coverage claim for them.

## The four oracles, and what a failure means

Checked between batches (`--batch`, default 25):

| Oracle | Catches | How |
| --- | --- | --- |
| liveness | main-thread stalls | the channel is delivered on the **main queue**, so a timeout whose recovery probe is *also* slow is a stall. The app is sampled first, then re-probed; a stall it recovers from counts against `--max-stalls` (default 3). A timeout that probes clean was a slow verb — journaled `slow`, uncounted. `VERB_TIMEOUTS` keeps each client deadline above the verb's in-app wait, or work in progress reads as an unresponsive app |
| `check_consistency` | inconsistent state | violations surviving a settle and a second sample. Its `cloud.*` checks skip that filter: their counters are cumulative for the fake's install, and neither a background download inside a foreground one nor a duplicate download is ever *transiently* true |
| `dump_health` | leaks, unbounded growth | footprint, fds, threads, mach ports, windows, views, layers, engine nodes, `pending` counters, each against a post-warmup baseline; a tighter at-rest series every `--quiesce-every` batches |
| crash | death | `pgrep`, plus any `Vibe*.ips` in `~/Library/Logs/DiagnosticReports` newer than the run |

Failure kinds: `hang`, `crash`, `exit`, `consistency`, `resource`, `command`, `client`. **`exit` is the app quitting on request, not dying** — gone *with* a fresh `.ips` is `crash`, gone *without* is `exit`. **`client` is the harness, not the app** (see traps). On failure the driver writes `stress-<seed>-failure/` (sample or crash report, `dump_state`, `dump_view_tree`, `dump_health`, screenshot) and prints the shrink command.

**Reading a `resource` failure.** Rules, each earned by watching the oracle cry wolf:

- **`mallocLiveBytes` is the sensitive megabyte metric; `phys_footprint` is a gross backstop (+256 MB).** The footprint is the allocator's and VM's high-water mark, wanders hundreds of MB in *both* directions at rest with the live heap flat, and a sanitizer build's shadow memory alone clears it. It now counts only when `mallocLiveBytes` agrees. Check the live heap before believing a footprint number, and shrink on live heap, never footprint.
- **`pending` counters must all be zero at rest** — a stranded claim or undelivered result is a few hundred bytes, invisible to any megabyte metric, yet work that will never finish. `quiesce` refuses to settle until they unwind and names the holdout.
- Baseline is the element-wise **minimum of the first three samples**, and a metric fails only after **three consecutive** over-limit samples: the opening decode peaks far above resting; engine nodes are flat now that the voice bus is built once, and `retiredFades` counts voices still fading, which drain within the crossfade length.
- `quiesce.pressureRelief.releasedBytes` is what `malloc_zone_pressure_relief` actually returned — mostly 0 after a heavy run.
- `--ignore-metric NAME` stands down a finding that is *already diagnosed*, so it stops masking what op 5,000 would have found.

Every metric in the table was audited against an external tool (`references/health-metrics.md`). **Do the same before trusting a new one**: a metric nobody has checked against ground truth is a number, not a measurement. The counter catalog, the settled footprint investigation, the layer bistability and what this driver cannot reach are all in that file.

## Shrink to repro

```bash
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --shrink build/stress/stress-48213.ndjson
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --shrink <journal> --shrink-resting-mb 150
```

`--shrink` delta-debugs the journal to a minimal op list, relaunching the app per candidate, and writes plain command-script lines for `run-script.sh`. A 5,000-op crash teaches nothing; the six-op version is a regression case. The default predicate covers crashes, hangs and consistency violations; `--shrink-resting-mb N` adds an at-rest footprint above N MB — and, per the rule above, that chases high-water noise; prefer a live-heap threshold.

**Worked example, the nil-metadata crash**: `renderState` passed `track.metadata.fileInfoLine` — nil whenever the scan had not landed — into `-[NSAttributedString initWithString:]`, which raises. Trigger is **a large file plus a cold cache**; unparseable files did *not*, since the error branch passes a literal. Reproduce with `open <large file>` on a cold cache, not a corpus of broken files.

## Traps

- **TRAP: the old random clicker was not contained by the app event queue.** A posted drag could pick up a real file from artwork or playlist rows, or hand an empty waveform to native window dragging. It also activated Vibe repeatedly and aimed using stale geometry. Excluding close/minimize rectangles only stopped accidental exits. Random input and its geometry/exclusion machinery have been removed; do not reintroduce them under another profile or recovery path. The driver still distinguishes an app disappearing **with** a fresh `.ips` (`crash`) from one disappearing **without** a report (`exit`, an apparent clean termination). Reporting the latter as a crash sends you hunting for a stack that was never written.
- **TRAP: never `sample Vibe` by name.** The CLI client *is* the app binary, so the name matches every in-flight `--debug-cmd`, and its stack (`VibeDebugClientRunOne` in `usleep`) reads as a hang. Resolve the GUI pid — `pgrep -x Vibe` filtered for an argv lacking `--debug-cmd` — and sample *before* re-probing: a probe that succeeds means the stall ended and took its stack with it.
- **TRAP: a toggled setting persists across runs, and a disabled feature looks exactly like a clean run.** `AppSettings` is `NSUserDefaults`, so a run inherits the last run's final random toggle; with folder art off the accessors never reach the resolver and nothing in the summary says so. The driver forces every `FEATURE_SETTINGS` entry on at launch and prints it (`settings: folderArt=on`), and the toggle ops (`folder_art`, `toggle_size` under `playlist`/`theme`) emit `off` then straight back `on` — that pair is load-bearing. **Verify a coverage claim's duty cycle from the journal** before believing it.
- **TRAP: `open -a <path>` resolves by BUNDLE ID, not path.** Every build is `com.commonwealthrecordings.Vibe`, so it launches whichever copy LaunchServices registered; a fix-vs-pre-fix comparison tests one binary twice. `VIBE_APP` does not save you (`launch.sh` hands it to `open -a`), and `lsregister -f` can leave *both* running. Direct-exec and verify with `ps -o comm=` — what `run-torture.sh` does.
- **TRAP: a second instance answers the channel, then the channel stops answering.** Presents as "app never answered" against a healthy idle main thread. `pgrep -x Vibe` also matches the **iOS Simulator's** Vibe (exclude `*CoreSimulator*`), and an **Xcode** debug session is a second instance too — check before anything that pkills.
- **Do not debug the harness while a driver is running.** Stop it, confirm no Vibe is up, then investigate; a background run relaunching the app underneath you looks like a broken channel.
- **TRAP: a concurrent Xcode build swaps the binary under a run.** `build/DerivedData` is Xcode's path too; nothing marks the seam. For an attributable run build to a private `-derivedDataPath` and pass `--app`.
- **TRAP: `--iterations` (default 2000) silently caps `--duration`** — whichever is reached first ends the run, so raise both for a soak.
- **TRAP: the sandbox kills clients under launch pressure.** Hundreds of quick client launches make libsecinit fail, SIGTRAPping in dyld initializers before `main()` — a real `Vibe` `.ips` with `parentProc: Python`, sub-millisecond lifetime, stack topped by `_libsecinit_appsandbox`. The driver retries a signal-killed client that produced no output and reports `client` only when retries are exhausted; do the same in any hand loop over `--debug-cmd`.
- **TRAP: the corpus grant is what makes direct-exec and sanitizer runs possible.** The driver launches through `launch.sh` with the corpus dir because `open -a` is what grants sandbox access, and the grant persists. Sanitizer options are environment variables, which `open -a` cannot pass, and a direct-exec `"$V" <file>` cannot read argv paths under the sandbox — but once the folder is granted a direct-exec launch reaches every file in it through the channel. `launchctl setenv` is the only way an `open -a` launch sees a variable.
- **TRAP: never add a TSan `suppressions=` file.** It deadlocks the launch before `main()` — `__tsan::Initialize` opens it inside dyld's initializers and that `open()` never returns under the sandbox. No log, no channel, indistinguishable from the `log_path` trap in `references/sanitizers.md`. Filter framework noise afterwards instead.
- **Deliberately excluded from every profile**: `convert_to_flac`, which writes beside the source and can trash the original — the corpus is real music. All raw input is excluded. The menu allowlist covers transport, playlist selection/removal, undo/redo, FX, pitch range and selected View actions; it excludes panels, Finder, clipboard writes, device changes and other OS-facing actions. Menu actions run live validation, so disabled items are expected. Discovery warns by identifier about every missing allowed item (including FX omitted when its graph is off), and an unreadable menu fails startup. Add new actions deliberately at the command gate, with a runner test.

## Supporting files

- `references/profiles.md` — every stress profile and torture phase, the op kinds that exist for one reason, the corpus builders, what is unreachable from this driver.
- `references/health-metrics.md` — the `pending` counter catalog, the settled footprint investigation, the layer bistability, the metric audit.
- `references/cloud-scenarios.md` — the five scenario rules, the registry and XFAIL contract, live-vs-XCTest ownership, `block_main`.
- `references/sanitizers.md` — getting a report out of a sandboxed app, the three builds, malloc-debug variants, `--client-app`.

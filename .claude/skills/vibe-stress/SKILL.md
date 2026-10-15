---
name: vibe-stress
description: Stress, soak, fuzz, and torture the running Vibe app against a folder of real audio files — seeded random controller actions without pointer input, with consistency, leak, hang, and crash oracles, a single-playlist skip/seek torture suite for the delivery races that only open when transport outruns the metadata scan, a deterministic cloud-loading scenario suite over a fake file provider (download ordering, the foreground hold, the open deadline), plus the sanitizer (ASan/UBSan/TSan) and malloc-debug build matrix. Use for soak or endurance runs, memory-leak and resource-growth hunting, race hunting, fuzzing the file-loading path, hammering skips and seeks on a large playlist, testing cloud/placeholder loading order, or minimizing a failing run to a repro.
---

# Stress and fuzz testing Vibe

**Read the `vibe-debug` skill first.** Everything here rides its `--debug-cmd` channel and launches through its `launch.sh`, so its traps (grant rules, off-hardware flags, two-instance raciness, the stale-binary check) all apply. The oracle verbs (`dump_health`, `check_consistency`, `quiesce`, `dump_cloud_trace`, `dump_equalizer`) are ordinary channel commands.

Needs a **Debug** build, since the channel compiles out of Release. Each script's `--help` is the authority on its flags.

Five drivers, five questions:

- **`stress.py`** randomizes controller actions for hours and notices when something breaks. Every profile is command-only: no raw mouse or keyboard events.
- **`torture.py`** loads one large playlist and hammers transport so track changes outrun everything async.
- **`cloud-scenarios.py`** drives one named situation and asserts what the fake provider's trace must contain. The cloud guarantees are about order, which random driving cannot state.
- **`device-flap.py`** makes the output device disappear and return, hundreds of times, and asserts playback survived. It is deliberately kept out of the stress profiles.
- **`bitperfect-soak.py`** plays a mixed-rate corpus at settle pace and asserts the bit-perfect and exclusive modes engage, follow each file's rate and restore the device.

**Unattended stress must leave desktop input alone.** `Channel` allows only reviewed controller and delegate commands and a small set of app-only menu identifiers. It rejects raw `click`, `drag`, `mouse_*`, `key*`, arbitrary `script` wrappers and unknown verbs, including inside nested `block_main` calls. Single commands, batches, journals, replay and shrink all pass this gate. A journal containing input is rejected before replay or shrink launches the app. No flag unlocks random input.

**Never recover a stress failure with global input.** Do not use `input.swift`, Accessibility mouse driving, AppleScript or computer-use clicks to unstick or extend a run. Capture diagnostics and stop. App-local NSEvents are not containment either: artwork and playlist handlers can start native file drags, and the waveform and background can start window drags.

## Running each suite

**Stress.** Every run records its commands. The seed prints first, every op is journaled as NDJSON under `build/stress/`, and `--replay` re-runs a journal verbatim, which reproduces the commands but cannot reproduce asynchronous scheduling. `--seed N` regenerates the same op sequence only while the app answers the same, since row selections, drop coordinates and theme and menu picks read live state. Without the seed or the journal a fuzz failure is nearly worthless.

```bash
make stress CORPUS=~/Music/big
make stress CORPUS=~/Music/big ARGS="--profile loading --duration 3600 --iterations 100000"
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --replay build/stress/stress-48213.ndjson   # replay exactly
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --seed 48213    # regenerate: same ops while live state agrees
```

By default, validated batches travel through one `script -` invocation. `--no-batch` uses one client per operation when individual timing matters.

**iOS stress and replay.** `stress.py --ios <exact simulator UUID>` attaches through `debug-ios.sh` to an already launched Debug app. It never launches, rebuilds, terminates or drives a phone. Use a dedicated simulator that stays in the foreground, with no other driver on it. The run replaces the playlist and leaves playback paused. It restores repeat, shuffle and Pause at track end. It also restores the favorites it starred, Recents, the tab, the card and the route indicator, and disarms the fake Dropbox and web server. These restorers run on pass, failure, `^C` and SIGTERM. FX must start enabled and released. A per-simulator lock excludes other instances of this runner.

```bash
# Seed at least two long local files; row 0 must be >= 60 s. Subfolders give
# `browse` something to walk. VIBE_IOS_APP selects a build.
VIBE_SIM_UDID=<uuid> .claude/skills/vibe-debug/scripts/launch-ios.sh <file1> <file2>
DATA=$(xcrun simctl get_app_container <uuid> com.commonwealthrecordings.Vibe data)
make stress CORPUS="$DATA/Documents/Music" ARGS="--ios <uuid> --seed 1152001 --iterations 200 --ios-rounds 3"
# Replay; corpus.json and settings.json must stay beside the recipe.
make stress CORPUS="$DATA/Documents/Music" ARGS="--ios <uuid> --replay build/stress/ios-<seed>-<unique>/replay.ndjson"
```

Each iOS run writes a unique directory under `build/stress/` with the seed, arguments, build provenance, executable hash, a content-hashed corpus manifest, playback settings, every command and reply, a replay recipe and the result. Replay accepts a different build but refuses different corpus contents, folder order, crossfade or BPM settings, or a different favorites list. Recipes keep command and check order. Polls and their deadlines are regenerated, so original wall-clock timing is not reproduced. The waits for a listing, an open's landing and a star are polls too.

The lifecycle pass checks pause → actual idle → resume, a verified FX tail before idle, resume before idle, and replacement playback before idle. Weighted ops follow (`IOS_WEIGHTS`): transport, seek, FX and burst, and the shell's screens. `tab`, `card`, `browse`, `search`, `favorite`, `route`, `page`, `fake_dropbox` and `link` are in `references/profiles.md`. Position movement is checked before any recovery play can hide a stall. Every batch reopens the corpus if an op replaced the playlist, then plays row 0, verifies progress, pauses, drains output and checks consistency. At the end, `dump_cloud_health`'s pending counters must reach zero, since iOS has no `quiesce`. The run prints how often each op was drawn and warns about an op that never did its work (`IOS_OP_PROOFS`). `--iterations 0` runs lifecycle checks only. `--ios-rounds 0` skips them. SIGINT and SIGTERM stop driving and attempt bounded cleanup. SIGKILL cannot restore settings.

The default `--ios-output pump` verifies `noAudioHw` at startup. For **real RemoteIO**, relaunch with `VIBE_AUDIBLE=silent` and pass `--ios-output remoteio --isolated-host-audio`. That flag acknowledges a stable host default output (built-in speakers suit), no simultaneous macOS device, rate or exclusive tests, and no other simulator audio driver (`vibe-debug`'s iOS loop). The runner does not change host audio. A pump pass does not cover RemoteIO. Neither covers physical-device interruptions, route changes or background playback. The `route` op redraws only the indicator. The open RemoteIO abort is `docs/bugs/open-issues.md`, "iPad simulator aborts in RemoteIO stop".

**The corpus.** `~/Music/big` stands for any folder of a few hundred distinct real files. With none, the drivers exit at startup. Without a library, build one from the generated audio. APFS-clone (`cp -c`) `build/streaming-fixtures/source/*` or `build/bench/corpus`'s `play/*` and `extra/*` (`python3 .claude/skills/vibe-perf/scripts/perf.py corpus` regenerates them) a dozen times each under distinct names, plus `Assets/test_audio_files/`, into `build/stress-corpus` (about 300 files). Distinct names give distinct cache keys. Grant it once with `launch.sh build/stress-corpus` before `run-torture.sh`, which direct-execs and cannot grant. `make clean` removes the corpus.

Profiles (`--profile`): `base`, `loading`, `hammer`, `ui`, `cloud`, `theme`, `playlist`, `artwork`. What each weights and why is in `references/profiles.md`. `cloud` and `artwork` need purpose-built corpora (`make-cloud-corpus.py`, `make-hostile-corpus.py`), and cue sheets have their own (`make-cue-corpus.py`).

**Torture.** One playlist, no settle anywhere, ops batched through `script -` (about 15 track changes per second). Phases come from `--phases` (default `skip,seek,mixed,jump,blocked,boundary`; `references/profiles.md`). Between bursts it checks the app is alive, `check_consistency`, and fds, hosted units, live heap and views against baseline. At the end a `quiesce` must find every `pending` counter at zero.

```bash
make torture PLAYLIST=~/Music/big                      # APP= defaults to the Debug build
make torture PLAYLIST=~/Music/big ARGS="--rounds 40 --burst 40 --seed N"
```

**Run it through `run-torture.sh`, never `torture.py` by hand.** The wrapper asserts that exactly one mac instance is up, that it is the intended binary, and that the caches are cold. The app outlives the run, so its output goes to `build/stress/torture-app.log`. The wrapper redirects the app’s three streams, so piping the runner does not wait for the app to exit. Quit the test instance between runs. **Cold caches are the point**: the delivery races only open while a scan is in flight as playback starts, so a warm pass proves far less than it looks.

**Cloud scenarios.** One fresh app launch per scenario. Run `make check-cloud-scenarios` (the runner's oracle tests, also part of `make test`) first.

```bash
.claude/skills/vibe-stress/scripts/make-cloud-corpus.py --out build/cloud-scenarios-corpus --folders 3 --per-folder 14
.claude/skills/vibe-stress/scripts/cloud-scenarios.py --corpus build/cloud-scenarios-corpus
.claude/skills/vibe-stress/scripts/cloud-scenarios.py --corpus <dir> --only S4b,S7 --verbose
```

The first two corpus folders must each hold 6–40 playable files. A clean report is **`PASS=24`** with no `FAIL` or `ERROR`. `XFAIL` does not fail the run. `XPASS`, `FAIL` and `ERROR` do, and an `XPASS` is a finding: the gap closed or the scenario stopped reaching it. The rules, the registry and the `block_main` instrument are in `references/cloud-scenarios.md`.

`--provider real --folder <iCloud Drive folder>` runs 14 of the scenarios against a real provider, with no fake. Its folder preparation, assertions, limits and clean result (`PASS=14  SKIP=10`) are in that reference's "Real provider" section.

The suite takes about ten minutes, and silence reads as stalled. Run it with its output in a file under a Monitor tailing that file (`tail -f <log> | grep -E --line-buffered ' \.\.\. .*(PASS|FAIL|ERROR)|PASS=|Traceback'`), and relay each scenario's outcome as it arrives. A busy check with `pgrep -f` matches the Monitor's own command line, so match `[Pp]ython[0-9]* .*cloud-scenarios\.py` instead.

**Device flap.** Does playback survive the output device going away and coming back? `--mode vanish` builds a public aggregate over a real device, makes it the system default and destroys it, so the default device ceases to exist, as a sleeping USB DAC does. `--mode move` only reassigns the default between two devices that both persist, a weaker stimulus. Each flap checks playback state and a moving position, `check_consistency` and that the app is alive. `dump_health` is sampled every `--health-every` flaps, and any rise in `outputDropouts` or `renderRefusals` fails. A closing `quiesce` must find every `pending` counter at zero.

```bash
.claude/skills/vibe-stress/scripts/device-flap.py --corpus ~/Music/big --device <id> --flaps 250
.claude/skills/vibe-stress/scripts/device-flap.py --corpus ~/Music/big --device <id> --device-b <id> --mode move
```

`--device` is an `AudioDeviceID`, which **changes whenever the device re-enumerates**, so read it fresh. The Swift helper beside the script is rebuilt on demand.

- **TRAP: this moves audio for every app on the machine.** That is why device changes stay out of the stress profiles, and why this runs deliberately, never unattended. It restores the original default on every exit path but SIGKILL, which can leave the default moved and strand a public aggregate.
- **TRAP: vanish mode degrades coreaudiod, and the damage outlives the run.** A few hundred vanishes can leave the daemon unable to start IO for any process until `sudo killall coreaudiod`. The script refuses more than 250 vanish flaps without `--i-know-this-degrades-coreaudiod` (its `TRAP:` comment has the detail).
- **TRAP: every flap must begin playing, or the silent-stop oracle passes vacuously.** The at-rest `quiesce` empties the playlist, so the driver reopens the corpus through `open` and fails any flap that begins not playing. Judge the heap at rest, against a no-flap control at the same cadence.
- **TRAP: a clean run does not clear the hardware path.** A destroyed software aggregate returns in microseconds. A real DAC waking from sleep takes seconds, which is where a real device's rebind delay lives. Only power-cycling real hardware tests that, and it cannot be automated.

**What a device change costs.** The helper's `rotate` mode cycles the system default across a list of real devices, creating nothing. Read the output unit's `AudioOutputUnit: bind to device N took`, `start on device N took` and `stop took` lines.

- **TRAP: Vibe must be on System Output for a rotation to test anything.** An explicitly bound device does not follow the default, so the rotation produces zero rebinds and looks like a success. Check `dump_state.player.requestedOutputDeviceId` is -1 first.
- **TRAP: a rebind pays for the device it leaves as well as the one it joins.** Binding to a new device waits for the old device's IO to stop. Read the stop line before attributing a cost. Bind cost does not track device quality.
- The output unit waits on the HAL on its own queue, so a play submitted during a rebind is admitted at once, within a few milliseconds. A play that waits the bind out on the player queue is the regression. Submit a `play_index` every 0.35 s during a rotation and read `Timeline: play N admitted after X ms on player queue` against the bind and start lines.

**Real output.** The drivers default to the pump. Real-HAL coverage is opt-in with `VIBE_AUDIBLE=silent`, with buffers zeroed. Select the intended device before opening audio. Silence alone does not prevent Bluetooth switching.

- **TRAP: "playing" is intent, not sound, and a locked Mac can deliver none.** With the lock screen's password prompt up, no process may get a render callback on any device, while output units start and stop cleanly. Unlocking fixes it; a coreaudiod restart does not. Run real-output suites (torture or any profile under `VIBE_AUDIBLE=silent`, device-flap, bit-perfect) on an unlocked Mac. When one fails with stuck `retiredFades` or a still position, check `dump_audio_path`'s output `renderCycles` before suspecting the engine.
- **TRAP: an occluded, paused app is deferred by the OS, on the pump too.** Once the window is covered and nothing plays, the whole process can sleep: timers do not fire and the channel's wake-up is not serviced for up to about 20 s. The client times out (`exit 1`) against an idle main thread with no stall report. The cloud scenarios that pause then fail with `could not restore On track end`. `launch.sh` and `run-torture.sh` order the window front after every launch (`raise_window`) and warn when it stays occluded. `-NSAppSleepDisabled YES` alone does not prevent it. A sleeping display or locked screen occludes every window, so that warning means wake and unlock the Mac.

**Bit-perfect and exclusive output.** `bitperfect-soak.py` checks settled mode transitions. `make test-bit-perfect` covers the loopback acceptance matrix. Per track, at settle pace, it asserts status Active, the device at **that file's** rate (read from `afinfo`, never from the app), the bus and output unit at that rate, no varispeed, `rateExact`, `formatConfirmed`, `channelsMatch` and `depthOK` true, and the hog held. Then a mode toggle must release the hog and return to Active or Idle, with the device's nominal rate back where it started, read from the HAL.

```bash
.claude/skills/vibe-stress/scripts/bitperfect-soak.py --corpus Assets/test_audio_files/rates \
    --device <id> --device-name "<its Output row>" --rounds 2
```

- **TRAP: torture cannot test either mode, and passes anyway.** A bit-perfect switch needs about a second to confirm, and torture changes tracks faster. The mode sits in `switchFailed` for the whole run, and exclusive output never takes the hog. A disabled feature looks exactly like a clean run.
- **TRAP: the System Output row embeds the default device's name**, so a `--device-name` can match `System Output (<name>)` first. That row is never eligible, so the run dies looking like a device fault. The matcher excludes System Output rows and prefers an exact match. Keep it that way.
- A device's own volume below unity is a truthful `volumeScaled`. The driver holds each target's settable volume at 1.0 for the run and restores the prior values on every exit but SIGKILL.
- A rate the hardware lacks is not a failure. The driver reads `kAudioDevicePropertyAvailableNominalSampleRates` and requires `rateUnsupported` for those tracks.

**Sanitizer matrix.** Three builds catch disjoint classes. **TSan matters most**, because the threading contract (pipeline mutations on the player queue, non-blocking getters, delegate callbacks on main) is invisible to every other oracle.

```bash
C=~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp
xcodebuild -project Vibe.xcodeproj -scheme Vibe -configuration Debug \
    -derivedDataPath build/DerivedData-tsan -enableThreadSanitizer YES build
launchctl setenv TSAN_OPTIONS \
    "log_path=$C/tsan:halt_on_error=0:external_symbolizer_path=:symbolize=1:history_size=7"
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big \
    --app "$PWD/build/DerivedData-tsan/Build/Products/Debug/Vibe.app" --profile artwork --max-stalls 20
launchctl unsetenv TSAN_OPTIONS        # session-wide until unset
```

`--tsan-replay <journal>` with `--app` set to the TSan build does the setenv, the replay, the quit and the unsetenv in one step, then prints each report's first stack. It is the last step of a stress failure's chain (`references/sanitizers.md`). `-enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES` is a second build. It is incompatible with TSan and about 3x slower. Aim it at malformed files, where input reaches TagLib's C++. Reports land as `$C/tsan.<pid>`, and **no file means no report was written**. The container-path and symbolizer rules, the malloc-debug variants and `--client-app` are in `references/sanitizers.md`.

## Named gesture tests, separate from stress

Use these only when the gesture itself is under test, on a **dedicated test Mac or disposable macOS VM**, with a Debug app already running. The flag asserts that isolation exists. It does not create it, and a different Space on the user's desktop is not isolation.

```bash
.claude/skills/vibe-stress/scripts/stress.py --gesture-test pitch-reset --isolated-desktop
.claude/skills/vibe-stress/scripts/stress.py --gesture-test pitch-drag --isolated-desktop
```

These are bounded tests of the pitch fader. They resolve and hit-test fresh geometry just before queuing a complete gesture and require the player and fader to reach the expected pitch. They restore the starting pitch and panel visibility even on failure. An unavailable or covered target fails rather than trying elsewhere. They cannot combine with replay or shrink. Other gestures are `vibe-debug`'s [OS-input reference](../vibe-debug/references/os-input.md). Normal stress makes no coverage claim for them.

## The five oracles, and what a failure means

Checked between batches (`--batch`, default 25):

| Oracle | Catches | How |
| --- | --- | --- |
| liveness | main-thread stalls | The channel is delivered on the main queue, so a timeout whose recovery probe is also slow is a stall. The app is sampled first, then re-probed. A recovered stall counts against `--max-stalls` (default 3). A timeout that probes clean was a slow verb, journaled `slow` and not counted. `VERB_TIMEOUTS` keeps each subprocess deadline above the client's per-verb timeout |
| `check_consistency` | inconsistent state | violations surviving a settle and a second sample. Its `cloud.*` checks skip that filter, since their counters are cumulative and never transiently true |
| `dump_health` | leaks, unbounded growth | footprint, fds, threads, mach ports, windows, views, layers, hosted units, render refusals and `pending` counters against a post-warmup baseline, plus a tighter at-rest series every `--quiesce-every` batches |
| crash | death | `pgrep`, plus any `Vibe*.ips` in `~/Library/Logs/DiagnosticReports` newer than the run |
| progress | work that silently stops | Each batch: rows unresolved or cloud parses pending, no gate in force, and one progress signature across four samples fails. After each `quiesce`: a file with sound must advance its position and light the equalizer. `references/health-metrics.md` has the window and the gates |

Failure kinds: `hang`, `crash`, `exit`, `consistency`, `resource`, `stalled`, `command`, `client`. **`stalled` is work no longer attempted**: nothing grew, hung or died, yet nothing moved. **`exit` is the app quitting, not dying**: gone with a fresh `.ips` is `crash`, gone without one is `exit`. **`client` is the harness, not the app** (see traps). On failure the driver writes `stress-<seed>-failure/` (sample or crash report, `dump_state`, `dump_view_tree`, `dump_health`, screenshot) and prints the shrink command.

**Work that silently stops is the progress oracle's.** The other four ask whether something grew, hung, went inconsistent or died, so a capability that stops being attempted passes every one. The progress oracle flags *demand outstanding* (`dump_state.playlist.resolvedRows` below `count`, or `cloudParsesPending` above 0) with *cumulative progress flat* (the materialization coordinator's `requestsReady`, `requestsFailed` and `handleOpensCompleted`, and the resolved rows) and *no gate in force*. A gate is the foreground hold, a held cloud lane, a player still loading, or a transfer still running. `quiesce`'s zero `pending` counters and `cloud.handle_open_stranded` still catch the stranded-run form. After each `quiesce` the driver plays one file whose name says it has sound (`equalizer_reference`), past any quiet intro. Its position must advance, the meter must publish, and a band must be nonzero. The probe is scored only while the bars are visible and sourced, and the run prints how many probes were. **A run that prints `0 of N probes scored` never checked the equalizer.** Torture requires a playing track's position to advance at every checkpoint, after a grace for an open the burst left in flight. A state-only check is not output coverage.

**Reading a `resource` failure.**

- **`mallocLiveBytes` is the sensitive megabyte metric. `phys_footprint` is a gross backstop** (+400 MB in flight, +256 MB at rest), scored only while the live heap is also over its own limit (+128 MB in flight, +64 MB at rest). The footprint is the allocator's and VM's high-water mark and wanders hundreds of MB at rest with the live heap flat. Shrink on live heap, never footprint.
- **`pending` counters must all be zero at rest.** A stranded claim is a few hundred bytes, invisible to any megabyte metric, yet it is work that will never finish. `quiesce` names the holdout.
- The baseline is the element-wise **minimum of the first three samples** (two at rest). A metric fails only after **three consecutive** over-limit samples (two at rest).
- `quiesce.pressureRelief.releasedBytes` is what `malloc_zone_pressure_relief` returned, mostly 0 after a heavy run.
- **The resting series is scored by slope too.** Live heap, views and mach ports fail when both halves of the series and the whole rise faster than a long run could absorb. A slow leak then fails long before it crosses an absolute limit.
- A resting mach-port failure under `playlist` reads `heap <pid>` itself and names the known AppKit row-view purgatory, or says it is a new finding (`references/profiles.md`).
- `--ignore-metric NAME` stands down a finding that is already diagnosed, so it stops masking later findings. Read the driver's own note on the failure before reaching for it.

Cross-check new metrics against the external tools in `references/health-metrics.md`.

## Shrink to repro

```bash
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --shrink build/stress/stress-48213.ndjson
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --shrink <journal> --shrink-resting-mb 150
```

`--shrink` delta-debugs the journal to a minimal op list, relaunching the app per candidate. It writes command-script lines for `run-script.sh` (`.min.txt`) and the same ops as a journal (`.min.ndjson`) for `--replay` and `--tsan-replay`. The default predicate covers crashes, hangs and consistency violations. `--shrink-resting-mb N` adds an at-rest footprint above N MB, which chases high-water noise, so prefer a live-heap threshold. A crash that needs a cold cache reproduces only with a cold cache: clear caches before each candidate's trigger.

## Traps

- **TRAP: raw input can start native file and window drags.** Unattended runs send only app-owned actions: `require_command` fails closed on any verb outside `COMMAND_VERBS`, old journals included. Do not reintroduce random input under another profile or recovery path.
- **TRAP: never `sample Vibe` by name.** The CLI client is the app binary, so the name matches every in-flight `--debug-cmd`, whose stack (`VibeDebugClientRunOne` in `usleep`) reads as a hang. Resolve the GUI pid (`pgrep -x Vibe` filtered for an argv lacking `--debug-cmd`) and sample before re-probing. A probe that succeeds means the stall ended.
- **TRAP: a toggled setting persists across runs, and a disabled feature looks exactly like a clean run.** `AppSettings` is `NSUserDefaults`, so a run inherits the last run's final toggle. The driver forces every `FEATURE_SETTINGS` entry on at launch and prints it (`settings: folderArt=on`). The `folder_art` op emits `off` then `on` as a pair, and that pair is load-bearing. **Verify a coverage claim's duty cycle from the journal.**
- **TRAP: the store a run moves is the user's real one**, since the sandbox container is shared with the installed app. Stress, `--replay`, `--tsan-replay` and `--shrink` snapshot `dump_state.settings` and the window frame before forcing anything. Teardown removes every imported theme, sends a `SETTING_RESTORERS` command for each key that moved, and prints one `settings:` line naming what it restored and anything `STILL CHANGED`. Teardown also clears the slow volume and the fake web server, and closes Settings. It runs on pass, failure, `^C`, SIGTERM and SIGHUP, relaunching the app if it died. A SIGKILL or a hung app leaves the store moved. **A new op that writes a persisted value needs a restorer.**
- **TRAP: `open -a <path>` resolves by bundle id, not path.** Every build is `com.commonwealthrecordings.Vibe`, so it launches whichever copy Launch Services registered, and a fix-vs-pre-fix comparison tests one binary twice. `VIBE_APP` does not help, since `launch.sh` hands it to `open -a`. Direct-exec and verify with `ps -o comm=`, as `run-torture.sh` does.
- **TRAP: a second instance answers the channel, then the channel stops answering.** It presents as "app never answered" against a healthy main thread. `pgrep -x Vibe` also matches the iOS Simulator's Vibe (exclude `*CoreSimulator*`), and an Xcode debug session is a second instance too.
- **Do not debug the harness while a driver is running.** Stop it, confirm no Vibe is up, then investigate. A background run relaunching the app looks like a broken channel.
- **TRAP: a concurrent Xcode build swaps the binary under a run.** `build/DerivedData` is Xcode's path too. For an attributable run, build to a private `-derivedDataPath` and pass `--app`.
- **TRAP: `--iterations` (default 2000) silently caps `--duration`.** Whichever is reached first ends the run, so raise both for a soak.
- **TRAP: the sandbox kills clients under launch pressure.** Hundreds of quick client launches make libsecinit fail before `main()`: a `Vibe` `.ips` with `parentProc: Python` and a stack topped by `_libsecinit_appsandbox`. The driver retries a signal-killed client that produced no output and reports `client` only when retries run out. Do the same in any hand loop over `--debug-cmd`.
- **TRAP: the corpus grant is what makes direct-exec and sanitizer runs possible.** `open -a` grants sandbox access and the grant persists, so the driver launches through `launch.sh` with the corpus folder. Sanitizer options are environment variables, which `open -a` cannot pass, and a direct-exec launch cannot read argv paths. Once the folder is granted, a direct-exec launch reaches every file in it through the channel. `launchctl setenv` is the only way an `open -a` launch sees a variable.
- **TRAP: never add a TSan `suppressions=` file.** It deadlocks the launch before `main()` (`references/sanitizers.md`). Filter framework noise afterwards.
- **Deliberately excluded from every profile**: `convert_to_flac`, which writes beside the source and can trash the original, and all raw input. The menu allowlist covers transport, playlist selection and removal, undo and redo, FX, pitch range and selected View actions. It excludes panels, Finder, clipboard writes, device changes and other OS-facing actions. The Settings allowlist (`SETTINGS_SWITCHES`) is display and analysis switches only, each with a restorer. The gate refuses every other `settings_click`, and every `open_url` off the fake web server. Discovery warns about every missing allowed item, and an unreadable menu fails startup. Add new actions deliberately at the command gate, with a runner test.

## Supporting files

- `references/profiles.md`: every stress profile and torture phase, the single-purpose op kinds, the corpus builders, what this driver cannot reach.
- `references/health-metrics.md`: the `pending` counter catalog, what is stable at rest, footprint limits and external cross-checks.
- `references/cloud-scenarios.md`: the scenario rules, the registry and XFAIL contract, live versus XCTest ownership, `block_main`.
- `references/sanitizers.md`: getting a report out of a sandboxed app, the three builds, malloc-debug variants, `--client-app`.

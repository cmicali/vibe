# Sanitizer and malloc-debug runs

Getting a report out of the sandboxed app, the three builds, the cheap variants. Read before a TSan or ASan run, or when a sanitizer build dies without a report.

## Getting a sanitizer report out of a sandboxed app

**Default options make TSan kill the app instead of reporting**, and the crash looks nothing like a race: an `EXC_CRASH`/`SIGABRT` whose faulting stack is `__sanitizer::Die` under `ReportFile::ReopenIfNecessary` and `StartSymbolizerSubprocess`. That is the sanitizer failing to *report*. Two causes, both the sandbox:

- **`log_path` must be inside the app's own container**, in its `Data/tmp/`. `VIBE_APP=<the app> scripts/vibe-env.sh --print VIBE_CONTAINER` names the container. A slotted build has a container of its own. Anywhere else, including a scratch dir under `/tmp`, and the first report aborts the process on the write. With no `log_path` the report goes to stderr, which is nowhere for a GUI app launched by `open -a`.
- **`external_symbolizer_path=` must be empty.** Symbolizing spawns `atos`, which the sandbox denies; TSan then tries to report *that* failure and hits the first problem. Empty falls back to the in-process `dladdr` symbolizer: function names, no file or line, enough to place a race.

**Never add a `suppressions=` file.** It deadlocks the launch before `main()`:

```
libSystem_initializer → __guard_setup → wrap_strlcpy
  → __tsan::Initialize → InitializeSuppressions → ReadFileToBuffer → OpenFile → open()   [blocked forever]
```

The process stays alive, logs nothing and never registers the channel, so from outside it is indistinguishable from the `log_path` trap. Being inside the container does not help: `log_path` is opened much later in startup, `suppressions` is not. Live with the framework noise and filter afterwards.

**A long media-heavy TSan soak can die in TSan itself.** A crash whose stack is `__tsan::MetaMap::AllocBlock` → `Die`, under a VideoToolbox allocation, is the instrumentation's shadow metadata running out, not an app crash. Shorten the run rather than chase it.

## Launching

Options are environment variables. `open -a` cannot pass them, so `launchctl setenv` is the only route to an `open -a` launch; it is session-wide, so `launchctl unsetenv` when the run ends. A direct-exec launch takes them from the shell, but reaches files only through the corpus grant (`SKILL.md`, traps):

```bash
xcodebuild -project Vibe.xcodeproj -scheme Vibe -configuration Debug \
    -derivedDataPath build/tsan/DerivedData -enableThreadSanitizer YES build
APP="$PWD/build/tsan/DerivedData/Build/Products/Debug/Vibe.app"
C="$(VIBE_APP="$APP" scripts/vibe-env.sh --print VIBE_CONTAINER)/Data/tmp"
launchctl setenv TSAN_OPTIONS "log_path=$C/tsan:halt_on_error=0:external_symbolizer_path=:history_size=7"
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --profile ui --app "$APP" --max-stalls 20
launchctl unsetenv TSAN_OPTIONS
```

`stress.py` always relaunches through `launch.sh`, so options set in the shell never reach the app; `run-torture.sh` direct-execs and takes them from its environment (`TSAN_OPTIONS=… run-torture.sh …`), its report in `build/stress/torture-app.log`, the app's stderr.

Build to a **separate** derived-data path so the plain Debug build stays usable, and hand it to the driver with `--app` (which sets `VIBE_APP` for `launch.sh`). A slot's `make clean` removes only its own `build/DerivedData-<slot>`. It keeps `build/tsan/`. Reports land as `log_path.<pid>`; Confirm that the instrumented app launched and could write its report. TSan creates the file on the first report: **no file means no report was written**. Raise `--max-stalls`: instrumentation makes ordinary verbs slow enough to trip the liveness oracle.

## From a stress failure to a TSan report

A failing journal reproduces commands, not scheduling, so a race that failed once may never fail again on a plain build. Instrument the scheduling instead:

1. **Shrink** the journal on the plain build: `stress.py --corpus <dir> --shrink build/stress/stress-<seed>.ndjson`. Shrink writes the minimal ops twice: as script lines (`.min.txt`) and as a journal (`.min.ndjson`), which the next step takes.
2. **Replay it under TSan**: `stress.py --corpus <dir> --app <TSan Vibe.app> --tsan-replay <journal>`. It sets `TSAN_OPTIONS` through `launchctl setenv` with the options above, replays through `launch.sh`, restores the settings, quits the app and unsets the options. The unset runs on pass, failure, `^C`, SIGTERM and SIGHUP. Only SIGKILL leaves the options set for the session.
3. **Read the reports.** It collects every `tsan.*` written during the run in the tmp of the `--app`'s own container. It prints each report's warning line and first stack. A report fails the replay. No file means no report was written, so confirm the instrumented app launched before reading that as clean.

A race the journal reaches only sometimes needs repeats. Run step 2 a few times rather than lengthening one run, since a long TSan run can exhaust its shadow metadata.

**`--client-app`** runs a plain build as the channel *client* against the instrumented app: an instrumented client costs ~2.4 s per op against ~0.13 s. Build both from the same source.

## The three builds

- **plain Debug**: fastest, most iterations; logic, assertions and hangs.
- **`-enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES`**: ~3x slower; aim it at malformed files, where input reaches TagLib's C++.
- **`-enableThreadSanitizer YES`**: a separate build, incompatible with ASan. Matters most: the threading contract — every pipeline mutation on the serial player queue, non-blocking UI-facing getters, delegate callbacks on main — is a major target. TSan detects races exercised by the run; a clean run does not prove their absence.

## Cheap variants on the plain build

Use the same direct-exec launch with `NSZombieEnabled=YES`, `MallocScribble=1`, `MallocGuardEdges=1` or `MallocStackLogging=1`. The last is needed for `leaks Vibe` to give allocation stacks and for `malloc_history` to attribute zone fragmentation.

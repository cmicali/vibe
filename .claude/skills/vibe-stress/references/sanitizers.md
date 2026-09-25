# Sanitizer and malloc-debug runs against the sandboxed app: getting a report out, the three builds, the cheap variants. Read before a TSan/ASan run or when a sanitizer build dies without a report.

## Getting a sanitizer report out of a sandboxed app

**Default options make TSan kill the app instead of reporting**, and the crash looks nothing like a race: an `EXC_CRASH`/`SIGABRT` whose faulting stack is `__sanitizer::Die` under `ReportFile::ReopenIfNecessary` and `StartSymbolizerSubprocess`. That is the sanitizer failing to *report*. Two causes, both the sandbox:

- **`log_path` must be inside the app's container**, `~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/`. Anywhere else, including a scratch dir under `/tmp`, and the first report aborts the process on the write. With no `log_path` the report goes to stderr, which is nowhere for a GUI app launched by `open -a`.
- **`external_symbolizer_path=` must be empty.** Symbolizing spawns `atos`, which the sandbox denies; TSan then tries to report *that* failure and hits the first problem. Empty falls back to the in-process `dladdr` symbolizer: function names, no file or line, enough to place a race.

**Never add a `suppressions=` file.** It deadlocks the launch before `main()`:

```
libSystem_initializer → __guard_setup → wrap_strlcpy
  → __tsan::Initialize → InitializeSuppressions → ReadFileToBuffer → OpenFile → open()   [blocked forever]
```

The process stays alive, logs nothing and never registers the channel, so from outside it is indistinguishable from the `log_path` trap. Being inside the container does not help: `log_path` is opened much later in startup, `suppressions` is not. Live with the framework noise and filter afterwards.

## Launching

Options are environment variables. `open -a` cannot pass them, so `launchctl setenv` is the only route to an `open -a` launch; it is session-wide, so `launchctl unsetenv` when the run ends. A direct-exec launch takes them from the shell, but reaches files only through the corpus grant (`SKILL.md`, traps):

```bash
xcodebuild -project Vibe.xcodeproj -scheme Vibe -configuration Debug \
    -derivedDataPath build/DerivedData -enableThreadSanitizer YES build
TSAN_OPTIONS=halt_on_error=0 "$V" --no-audio-hw --silent &
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --profile ui   # app already up
```

Build to a **separate** derived-data path so the plain Debug build stays usable, and hand it to the driver with `--app` (which sets `VIBE_APP` for `launch.sh`). Reports land as `log_path.<pid>`; TSan creates the file only on the first report, so **no file means no race**. Raise `--max-stalls`: instrumentation makes ordinary verbs slow enough to trip the liveness oracle.

**`--client-app`** runs a plain build as the channel *client* against the instrumented app: an instrumented client costs ~2.4 s per op against ~0.13 s. Build both from the same source.

## The three builds

- **plain Debug**: fastest, most iterations; logic, assertions and hangs.
- **`-enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES`**: ~3x slower; aim it at malformed files, where input reaches TagLib's C++.
- **`-enableThreadSanitizer YES`**: a separate build, incompatible with ASan. Matters most: the threading contract — every pipeline mutation on the serial player queue, non-blocking UI-facing getters, delegate callbacks on main — is exactly what it validates, and a race there is invisible to every other oracle.

## Cheap variants on the plain build

Same direct-exec launch: `NSZombieEnabled=YES`, `MallocScribble=1`, `MallocGuardEdges=1`, `MallocStackLogging=1` (needed for `leaks Vibe` to give allocation stacks and for `malloc_history` to attribute zone fragmentation). `heap Vibe` gives per-class live instance counts from outside the process.

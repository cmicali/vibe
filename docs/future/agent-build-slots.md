# Future: per-agent build slots

**Status: Not built.**

## Problem

Concurrent agents build and run the macOS Debug app from one checkout. Every build has the same executable name, bundle id and sandbox container.

- Every quit path reaches every instance. `launch.sh` quits through a channel any instance may answer, then signals every non-simulator `pgrep -x Vibe` pid.
- One container means one channel. `VibeSweepStaleChannelFiles` (`DebugChannel.m`) deletes every `vibe-command-*`, `vibe-response-*` and `vibe-screenshot-*` file at launch. That destroys another agent's in-flight commands.
- One container means shared `NSUserDefaults`, PINCaches and folder-access bookmarks. These corrupt an agent's test silently.

Goal: each agent's Debug build gets its own executable, bundle id and container. Agents then cannot see, kill or interrogate each other. Release and App Store builds stay untouched. An unslotted build behaves exactly as today. iOS needs nothing, because `sim-udid.sh` already gives each session its own simulator.

The slot comes from `CLAUDE_CODE_SESSION_ID`, which Task subagents inherit. It never comes from the worktree name, since agents may share a checkout.

**What exists.** `scripts/build/build-lock.sh` is the checkout-wide `mkdir` lock. `make project`'s generate, `make build-ios`, `make test-audio`, `drive-ios.sh start` and the skill's `sim-install.sh` hold it. `scripts/build/build.sh`, `make test`'s xcodebuild, `scripts/build/install-ios.sh`, `scripts/build/analyze.sh` and `asc_generate_and_archive` do not. A CoreSimulator-filtered `pgrep -x Vibe` loop is copied into seven scripts: `launch.sh`, `run.sh`, `screenshot-lib.sh`, `clear-caches.sh`, `capture-window.sh`, `run-torture.sh` and `reset-state.sh`.

## Decisions

- **Slots are `xcodebuild` argv overrides, never `project.yml`.** Argv overrides are supported. Importing env vars into build settings is not verified. The generated project stays slot-free, and no release path can inherit a slot.
- **The bundle id takes a hyphen**, as in `com.commonwealthrecordings.Vibe-a71feaa3`. A hex slot can start with a digit, which a reverse-DNS component should avoid.
- **Notification names are bundle-scoped.** The container already keeps out a command file from the wrong app. A Darwin notification is global, so without this every main queue would wake on every command.
- **`CFBundleName` stays "Vibe".** `InfoPlist.xcstrings` pins it in every language. The Dock, menu bar and window owner read "Vibe" for every slot, so select windows and processes by pid.
- **The `os_log` subsystem is unchanged.** A slot's log stream adds `process == "$VIBE_PRODUCT"`.
- **`pgrep -x Vibe` does not match `Vibe-<slot>`.** Unslotted tooling cannot see a slot.
- `make test`'s real collision is DerivedData. The `/private/tmp/vibe-tests/` literals in the tests only build `NSURL`s.

| | stock | slot `a71feaa3` (Debug only) |
|---|---|---|
| executable | `Vibe` | `Vibe-a71feaa3` |
| bundle id | `com.commonwealthrecordings.Vibe` | `com.commonwealthrecordings.Vibe-a71feaa3` |
| DerivedData | `build/DerivedData` | `build/DerivedData-a71feaa3` |
| channel | `com.vibe.debug.command` | `com.commonwealthrecordings.Vibe-a71feaa3.debug.command` |

## Work

**`scripts/vibe-env.sh` is the one new file.** It replaces the seven copied loops. It is sourced and has no side effects, because release scripts source it only for its assertion. It offers `--print <key>` for the Python harnesses and runs under bash 3.2.

Resolution order:
1. `VIBE_NO_SLOT=1` means no slot.
2. Else `VIBE_SLOT`, which must match `^[A-Za-z0-9]{1,11}$`. A malformed value is a hard error.
3. Else the first 8 characters of a UUID-shaped `CLAUDE_CODE_SESSION_ID`.

It exports `VIBE_SLOT`, `VIBE_PRODUCT`, `VIBE_BUNDLE_ID`, `VIBE_DERIVED_DATA`, `VIBE_APP`, `VIBE_BIN` and `VIBE_CONTAINER`. A pre-set `VIBE_APP` wins, and its ids are read from its `Info.plist`. Its functions are `vibe_own_pids`, `vibe_quit_own` (by bundle id), `vibe_kill_own` and `vibe_assert_stock_bundle`.

**Build.**
- `scripts/build/build.sh` uses a per-slot `-derivedDataPath`. For a slotted Debug build it passes `PRODUCT_NAME=` and `PRODUCT_BUNDLE_IDENTIFIER=`, then checks that the product exists.
- `make test` uses per-slot DerivedData with no product overrides, since the scheme builds `VibeTests`.
- `make install` refuses a slotted Debug build.
- `scripts/build/clean.sh` removes only the slot's DerivedData. `--all` keeps today's wipe.
- Every generate that skips the build lock takes it.
- `generate-git-info.sh` writes a temp file, then moves it.

**Channel.**
- `kVibeDebugCommandNotification` (`DebugWireFormat.{h,m}`) becomes `VibeDebugCommandNotificationName()` and `VibeDebugScreenshotNotificationName()`. Both are formatted from `NSBundle.mainBundle.bundleIdentifier`. App and client are one binary, so both derive the same name.
- Callers to change: `VibeInstallDebugCommandChannel`, the `notify_post` in `DebugClient.m`, the literal in `VibeInstallDebugScreenshotHook`, and the comments in `DebugMacEntry.h` and `DebugChannel.h`.
- `dump_build` (`DebugCommonVerbs.m`) adds the bundle id, executable and resolved channel. Do not add a second instance report to `dump_state`.
- `VibeLogBuildProvenance` also logs the bundle id.

**Tooling.**
- The resolver replaces every `APP=` or `V=` preamble and every literal `Contents/MacOS/Vibe`. That covers the seven scripts above, `run-script.sh`, `scan-bpm.sh`, `scan-key.sh`, `validate-tempo.py`, `validate-key.py`, `stress.py`, `torture.py`, `device-flap.py`, `bitperfect-soak.py` and the Makefile's `AUDIO_APP`.
- `generate-readme-screenshots.sh`, `run.sh` and `screenshot-lib.sh`'s `quit_app` quit by bundle id.
- These select by pid: `find-window.swift`, `app_above_backdrop` (the pid column of `window-stack.swift`), `vibeBundleID` in `backdrop.swift`, and the running-app filter in `verify-bit-perfect.swift`.
- In `launch.sh`, an impostor is our executable at another path, and so in our container. It fails hard, kills nothing, and prints the `ps` line and the `lsregister -f` remedy. Another slot or a stock instance gets a stderr note and is never touched. When slotted, the answering-binary warning becomes an error.
- `vibe-debug/SKILL.md` gains a Slots section: source, override, opt-out, derived names and matching by pid. Its log predicate adds `process ==`. The root `AGENTS.md`'s `make build` row names the slot's DerivedData.

**Release.**
- `release.sh` and `release-appstore.sh` export `VIBE_NO_SLOT=1` and unset the `VIBE_*` names. They never refuse, since every agent shell has a session id.
- `vibe_assert_stock_bundle` checks for `Vibe.app`, the stock `CFBundleIdentifier` and `CFBundleExecutable` `Vibe`. It runs in `asc_export_archive`, which both pipelines share, and in `verify_release_variant` in `github-release.sh`.
- The literal `--bundle-id` in `appstore-upload-metadata.sh` stays. The literal is the safety property.

## Verification

Two shells on one checkout, slots `aaaa1111` and `bbbb2222`:

1. `VIBE_NO_SLOT=1` and an empty environment resolve today's literals. An unslotted Debug `Info.plist` is identical to today's. Concurrent slotted `make build CONFIG=Debug` runs both succeed.
2. `pgrep -x Vibe-aaaa1111` finds one pid. `pgrep -x Vibe` finds none.
3. `launch.sh` and `generate-readme-screenshots.sh` in A leave B's pid alive and answering. A file opened in A is absent from B's `dump_state`. `capture-window.sh` in A captures A's window.
4. A stock instance gets a note and survives. An impostor exits 1 with nothing killed.
5. `release.sh` from a slotted shell ships stock `Vibe.app`. The assertion fails a slotted one.

## Known limits

- Each slot creates a container and a LaunchServices registration of the cue-sheet UTI. It starts as a fresh profile, with empty prefs, cold caches and no grants. Never exercise the default-player claim there.
- Xcode IDE builds have no shell environment. They stay unslotted and collide as today.
- `tell application id … to quit` against a DerivedData bundle is unverified. TERM, then KILL, backs it.

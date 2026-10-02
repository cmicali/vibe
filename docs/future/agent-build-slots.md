# Future: per-agent build slots

**Status: planned, not implemented (verified 2026-09-27).**

## Problem

Concurrent agents build and run the macOS Debug app from one checkout, and every build has the same
executable name, bundle id, and sandbox container. So every quit path reaches every instance
(`launch.sh` quits through a channel any instance may answer, then signals every non-simulator
`pgrep -x Vibe` pid), and one
container means one channel: `VibeSweepStaleChannelFiles` (`DebugChannel.m`) deletes every
`vibe-command-*`, `vibe-response-*`, and `vibe-screenshot-*` file at launch, destroying another
agent's in-flight commands. Worst, one container means shared `NSUserDefaults`, PINCaches, and folder-access
bookmarks, which corrupt an agent's test silently.

Goal: each agent's Debug build gets its own executable, bundle id, and container, so agents cannot
see, kill, or interrogate each other. Release and App Store builds are provably untouched; unslotted
builds behave byte-for-byte as today. iOS needs nothing: `sim-udid.sh` already gives each session
its own simulator, so its own container and channel. The slot comes from `CLAUDE_CODE_SESSION_ID`,
which Task subagents inherit, never from the worktree name: agents may share a checkout.

**Already in place.** `scripts/build-lock.sh`, the checkout-wide `mkdir` lock, is held by `make
project`'s generate, `make build-ios`, `make test-audio`, `drive-ios.sh start`, and the skill's
`install-ios.sh`, but not by `scripts/build.sh` (its own generate or its xcodebuild, so `make
build`'s compile is unlocked), `make test`'s xcodebuild, `scripts/install-ios.sh`,
`scripts/analyze.sh`, or `asc_generate_and_archive`. A CoreSimulator-filtered `pgrep -x Vibe` loop
is copied into seven scripts: `launch.sh`, `run.sh`, `screenshot-lib.sh`, `clear-caches.sh`,
`capture-window.sh`, `run-torture.sh`, and `reset-state.sh`.

## Decisions

- **Slots are `xcodebuild` argv overrides, never `project.yml`.** Argv overrides are unambiguously
  supported (env-var import into build settings is not verified), the generated project stays
  slot-free and shareable, and no release path can inherit a slot the spec never names.
- **The bundle id takes a hyphen**, `com.commonwealthrecordings.Vibe-a71feaa3`: a hex slot can start
  with a digit, and a reverse-DNS component starting with one is best avoided.
- **Notification names are bundle-scoped.** The container already keeps a command file from the
  wrong app, but a Darwin notification is global, so every main queue would wake on every command.
- **`CFBundleName` stays "Vibe"** (`InfoPlist.xcstrings` pins it in 30 languages), so the Dock, menu
  bar, and window-owner name read "Vibe" for every slot: select windows and processes by pid.
- **The `os_log` subsystem is unchanged**; a slot's log adds `process == "$VIBE_PRODUCT"`.
- **`pgrep -x Vibe` does not match `Vibe-<slot>`**, so unslotted tooling cannot see a slot at all.
- The `/private/tmp/vibe-tests/` literals in `PlaylistTests.m`, `AudioTrackTests.m`, and
  `OpenBurstCoalescerTests.m` only build `NSURL`s; `make test`'s real collision is DerivedData.

| | stock | slot `a71feaa3` (Debug only) |
|---|---|---|
| executable | `Vibe` | `Vibe-a71feaa3` |
| bundle id | `com.commonwealthrecordings.Vibe` | `com.commonwealthrecordings.Vibe-a71feaa3` |
| DerivedData | `build/DerivedData` | `build/DerivedData-a71feaa3` |
| channel | `com.vibe.debug.command` | `com.commonwealthrecordings.Vibe-a71feaa3.debug.command` |

## Remaining work

**`scripts/vibe-env.sh`, the one new file**, replacing the seven copied loops. Sourced and
side-effect-free (release scripts source it for the assertion alone), `--print <key>` for the Python
harnesses, bash 3.2-safe. Resolution: `VIBE_NO_SLOT=1` → none; else `VIBE_SLOT`, validated
`^[A-Za-z0-9]{1,11}$` and a hard error when malformed; else the first 8 characters of a UUID-shaped
`CLAUDE_CODE_SESSION_ID`. Exports `VIBE_SLOT`, `VIBE_PRODUCT`, `VIBE_BUNDLE_ID`,
`VIBE_DERIVED_DATA`, `VIBE_APP`, `VIBE_BIN`, and `VIBE_CONTAINER`; a pre-set `VIBE_APP` wins, its ids
read from its `Info.plist`. Functions: `vibe_own_pids`, `vibe_quit_own` (by bundle id),
`vibe_kill_own`, and `vibe_assert_stock_bundle`.

**Build.** `scripts/build.sh`: per-slot `-derivedDataPath`, the `PRODUCT_NAME=` and
`PRODUCT_BUNDLE_IDENTIFIER=` overrides when Debug and slotted, and a check that the product exists.
Makefile `test`: per-slot DerivedData, no product overrides (the scheme builds `VibeTests`); `install`
refuses a slotted Debug. `scripts/clean.sh`: only the slot's DerivedData, `--all` for today's wipe.
The build lock around every generate it misses. `generate-git-info.sh`: write a temp file, then `mv`.

**Channel.** `kVibeDebugCommandNotification` (`DebugWireFormat.{h,m}`) becomes
`VibeDebugCommandNotificationName()` and `VibeDebugScreenshotNotificationName()`, formatted from
`NSBundle.mainBundle.bundleIdentifier`; app and client are one binary, so both derive the same name.
Callers: `VibeInstallDebugCommandChannel`, `DebugClient.m`'s `notify_post`,
`VibeInstallDebugScreenshotHook`'s literal, and the `DebugUtil.h` and `DebugChannel.h` comments.
`VibeStateDictionary` (`DebugStateDump.m`) gains an `instance` dict (bundle id, path, executable,
pid, channel), not `app`, which `dump_health` already uses; `VibeLogBuildProvenance` logs the bundle id.

**Tooling.** The resolver replaces every `APP=`/`V=` preamble and literal `Contents/MacOS/Vibe`:
the seven scripts above, `run-script.sh`, `scan-bpm.sh`, `scan-key.sh`, `validate-tempo.py`,
`validate-key.py`, `stress.py`, `torture.py`, `device-flap.py`, `bitperfect-soak.py`, and the
Makefile's `AUDIO_APP`. `generate-readme-screenshots.sh`, `run.sh`, and `screenshot-lib.sh`'s
`quit_app` quit by bundle id. Select by pid: `find-window.swift`, `app_above_backdrop`
(`window-stack.swift`'s pid column), `backdrop.swift`'s `vibeBundleID`, and
`verify-bit-perfect.swift`'s running-app filter. In `launch.sh`, an impostor (our executable at
another path, so our container) fails hard, kills nothing, and prints the `ps` line and the
`lsregister -f` remedy; another slot or a stock instance is a stderr note, never touched; the
answering-binary warning becomes an error when slotted. `vibe-debug/SKILL.md` gains a Slots section
(source, override, opt-out, derived names, match by pid) and `process ==` in its log predicate;
the root `AGENTS.md`'s `make build` row names the slot's DerivedData.

**Release.** `release.sh` and `release-appstore.sh` export `VIBE_NO_SLOT=1` and unset the `VIBE_*`
names, never refusing, since every agent shell has a session id. `vibe_assert_stock_bundle`
(`Vibe.app`, stock `CFBundleIdentifier`, `CFBundleExecutable` `Vibe`) runs in `asc_export_archive`,
which both pipelines share, and in `github-release.sh`'s `verify_release_variant`.
`appstore-upload-metadata.sh`'s literal `--bundle-id` stays: the literal is the safety property.

## Verification

Two shells on one checkout, slots `aaaa1111` and `bbbb2222`:

1. `VIBE_NO_SLOT=1` and an empty environment resolve today's literals; an unslotted Debug
   `Info.plist` is identical to today's. Concurrent slotted `make build CONFIG=Debug` both succeed.
2. `pgrep -x Vibe-aaaa1111` finds one pid; `pgrep -x Vibe` finds none.
3. `launch.sh` and `generate-readme-screenshots.sh` in A leave B's pid alive and answering; a file
   opened in A is absent from B's `dump_state`; `capture-window.sh` in A captures A's window.
4. A stock instance gets a note and survives; an impostor exits 1 with nothing killed.
5. `release.sh` from a slotted shell ships stock `Vibe.app`, and the assertion fails a slotted one.

## Known limits

- Each slot mints a container and a LaunchServices registration of the cue-sheet UTI, and starts as a
  fresh profile (empty prefs, cold caches, no grants); never exercise the default-player claim there.
- Xcode IDE builds have no shell environment, so they stay unslotted and collide as today.
- `tell application id … to quit` against a DerivedData bundle is unverified; TERM, then KILL, backs it.

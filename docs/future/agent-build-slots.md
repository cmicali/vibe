# Future: per-agent build slots

Written 2026-08-13, planned but not implemented. Nothing in the repo has changed for it yet — the
file:line anchors below are against `main` at that date and should be re-checked before acting.

The verified facts that shaped the design, in case they drift: `CLAUDE_CODE_SESSION_ID` is
exported into every agent shell **and inherited by Task subagents** (so an agent and its subagents
share one slot, while separate sessions differ); `CLAUDE_CODE_BRIDGE_SESSION_ID` is a differently
shaped `session_…` string, not the parent UUID; `pgrep -x Vibe` does **not** match `Vibe-a71feaa3`
on Darwin 25.5, which is what makes unslotted behaviour automatically isolated from slots.

Two things I initially believed and disproved, so they are not re-litigated: the
`/private/tmp/vibe-tests/` literal in `Tests/PlaylistTests.m:53`, `AudioTrackTests.m:41` and
`OpenBurstCoalescerTests.m:42` is **not** a concurrency collision (those tests only construct
`NSURL`s from it and never touch the filesystem — the real `make test` collision is the shared
DerivedData); and slotting via a `$(VAR)` in `project.yml` is **not** preferable to xcodebuild
argv overrides (see Decisions).

## Context

Multiple Claude Code agents build and run Vibe concurrently against this repo. Today every
build produces the same bundle id and the same executable name, so:

- `launch.sh:25` runs `pkill -x Vibe`, which kills **every** agent's instance, not its own.
- All instances share one sandbox container (`~/Library/Containers/com.commonwealthrecordings.Vibe`),
  so the debug command channel's files collide — and `DebugUtil.m:1471-1480` deletes every
  `vibe-command-*.json` at launch, destroying another agent's in-flight commands.
- The same container means shared `NSUserDefaults`, both PINCaches, and folder-access bookmarks.
  This is the worst part: it corrupts an agent's test silently, with no visible conflict.

Goal: an agent's Debug build gets its own bundle id, executable name and container, so agents
cannot see, kill, or interrogate each other. Release and App Store builds must be provably
untouched. Unslotted builds must behave **byte-for-byte** as today.

Identity comes from `CLAUDE_CODE_SESSION_ID` (verified: exported into every agent shell, and
**inherited by Task subagents**, so an agent and its subagents share one slot while separate
sessions get distinct ones). Deliberately **not** the worktree name — agents may share a checkout.

## Decisions

**Slot delivery: `xcodebuild` command-line overrides, not `project.yml`.**
`scripts/build.sh` passes `PRODUCT_NAME=` / `PRODUCT_BUNDLE_IDENTIFIER=` for Debug only.
`project.yml` is not modified at all. This is stronger than a Debug-scoped `$(VAR)` in the spec:
argv overrides are unambiguously supported (env-var import into the build-settings table is
*not* verified), `Vibe.xcodeproj` stays slot-free and shareable between agents, and no release
path can inherit a slot because nothing in the checked-in spec mentions one.

**Bundle id uses a hyphen, not a dot**: `com.commonwealthrecordings.Vibe-a71feaa3`. A hex slot
can begin with a digit, and a reverse-DNS *component* starting with a digit is best avoided.

**Notification names become bundle-scoped.** Container isolation alone already stops a *command*
reaching the wrong app, but the Darwin notification is global, so every instance's main queue
wakes on every agent's command. Scoping it satisfies the stated requirement literally and removes
main-thread churn in other agents' apps during timing-sensitive tests.

**`CFBundleName` is not touched.** `Resources/InfoPlist.xcstrings` pins it to "Vibe" in all 30
languages. Consequence to accept: the **Dock and menu bar still read "Vibe" for every slot**;
only the `.app` filename, the executable, and the `ps`/Activity Monitor process name differ.
Anything selecting by window-owner name must therefore become PID-driven.

**`os_log` subsystem stays `com.commonwealthrecordings.Vibe`** so the documented log predicate
keeps working; docs gain a `process == "$VIBE_PRODUCT"` filter to separate slots.

Derived identities for slot `a71feaa3`:

| | stock | slotted (Debug only) |
|---|---|---|
| product / executable | `Vibe` | `Vibe-a71feaa3` |
| bundle | `Vibe.app` | `Vibe-a71feaa3.app` |
| bundle id | `com.commonwealthrecordings.Vibe` | `com.commonwealthrecordings.Vibe-a71feaa3` |
| DerivedData | `build/DerivedData` | `build/DerivedData-a71feaa3` |
| container | `…/Containers/com.commonwealthrecordings.Vibe` | `…Vibe-a71feaa3` |
| channel | `com.vibe.debug.command` | `com.commonwealthrecordings.Vibe-a71feaa3.debug.command` |

## Implementation

### 1. `scripts/vibe-env.sh` (new) — the single resolver

Sourced by every script (dual-mode: `--print <key>` for the Python harnesses). Follows the
existing sourced-lib conventions of `scripts/asc-build-lib.sh`. Sourcing has **no side effects**
so release scripts can source it just for the assertion.

Resolution order: `VIBE_NO_SLOT=1` → empty; else `VIBE_SLOT` (validated `^[A-Za-z0-9]{1,11}$`,
**hard error** if malformed — never a silent fallback); else `CLAUDE_CODE_SESSION_ID` first 8
chars when UUID-shaped; else empty.

Exports `VIBE_SLOT`, `VIBE_PRODUCT`, `VIBE_BUNDLE_ID`, `VIBE_DERIVED_DATA`, `VIBE_APP`,
`VIBE_BIN`, `VIBE_CONTAINER`, plus `VIBE_STOCK_PRODUCT`/`VIBE_STOCK_BUNDLE_ID` for the guard.
A pre-set `VIBE_APP` stays authoritative, with `VIBE_BIN`/`VIBE_BUNDLE_ID` then read from that
bundle's own `Contents/Info.plist` via `PlistBuddy` — this is what fixes the ~9 scripts that
currently append a literal `Contents/MacOS/Vibe`.

Key functions: `vibe_env_init [config]` (slot naming applies to Debug only), `vibe_app_path
<config>` (ignores `$VIBE_APP`, for config-targeting callers), `vibe_own_pids` (filters
`pgrep -x "$VIBE_PRODUCT"` by argv[0] prefix — promotes `launch.sh:50-54`'s existing post-hoc
check into the selector), `vibe_pid`, `vibe_impostor_pids`, `vibe_other_pids`, `vibe_kill_own`,
`vibe_quit_own` (AppleScript **by bundle id**, never by name), `vibe_assert_stock_bundle`,
`vibe_slot_banner`. bash 3.2-safe throughout (no `mapfile`; the `${ARR[@]+…}` idiom per
`launch.sh:35-36`).

### 2. Build plumbing

- `scripts/build.sh:35-42` — `-derivedDataPath "$VIBE_DERIVED_DATA"`; append
  `PRODUCT_NAME=… PRODUCT_BUNDLE_IDENTIFIER=…` only when config is Debug **and** a slot is set.
  Assert the expected product path exists afterwards, so a silently-empty slot fails on the
  first build rather than mystifying later. Update the echo at `:42` and header at `:8`.
- `Makefile:29` (`test`) — per-slot `-derivedDataPath`; **no** product overrides (the test action
  builds `VibeTests`; renaming it would break scheme resolution).
- `Makefile:37-39` (`install`) — resolve the source path; fail loudly on `CONFIG=Debug` with a
  slot rather than installing a throwaway bundle id into `/Applications`.
- `scripts/clean.sh:24` — when slotted, remove only `$VIBE_DERIVED_DATA`; add `--all` for
  today's wipe-everything behaviour (it currently destroys every agent's build).
- `xcodegen generate` mutex — `mkdir`-based lock (macOS has no `flock(1)`) around the generate
  step in `scripts/build.sh:31` and `scripts/asc-build-lib.sh:34`; it writes both
  `Vibe.xcodeproj` and the generated `Vibe/Mac/App/Info.plist`, so a torn read is possible on a
  shared checkout. 60s timeout, clear message.
- `scripts/generate-git-info.sh:49-52` — write to `"$OUTPUT.$$"` then `mv` (atomic rename). The
  header is shared across slots; benign until the dirty flag flips mid-compile.

### 3. Channel isolation (source)

- `Vibe/Debug/DebugWireFormat.h:19` / `DebugWireFormat.m:10` — replace the
  `kVibeDebugCommandNotification` constant with `VibeDebugCommandNotificationName()` and
  `VibeDebugScreenshotNotificationName()`, each `dispatch_once`-cached, formatting
  `%@.debug.%@` against `NSBundle.mainBundle.bundleIdentifier` (fallback: the stock id).
  App and CLI client are the same binary in the same bundle, so both derive the same name.
- `Vibe/Debug/Mac/DebugClient.m:223` and `Vibe/Debug/Mac/DebugUtil.m:1481-1482` — use the function.
- `Vibe/Debug/Mac/DebugUtil.m:165` — the inline `"com.vibe.debug.screenshot"` literal likewise.
- `Vibe/Debug/Mac/DebugUtil.m` `VibeStateDictionary` — add an `app` dict (`bundleId`, `bundlePath`,
  `executable`, `pid`, channel name) so an agent can *prove* which instance answered, and so the
  screenshot notification name stays discoverable.
- `Vibe/Mac/App/AppDelegate.m:132-135` (`logBuildInfo`) — log the bundle id, making every log
  excerpt self-identifying.
- Doc strings naming the old constants: `Vibe/Debug/Mac/DebugUtil.h:21,26,61`.

### 4. Tooling (pattern: replace the `DIR`/`ROOT`/`APP`/`V` preamble with the resolver)

Representative files — same 3-line preamble in each:
`.claude/skills/vibe-debug/scripts/{launch.sh,clear-caches.sh,run-script.sh,slow-open.sh,scan-bpm.sh,scan-key.sh,capture-window.sh}`,
`scripts/screenshots/screenshot-lib.sh` (keep local `APP=`/`V=` aliases at `:27-28` so ~40
downstream uses are untouched), `scripts/run.sh`.
Every `pgrep -x Vibe` / `pkill -x Vibe` becomes `vibe_pid` / `vibe_kill_own`
(`launch.sh:25,32,50`; `clear-caches.sh:22`; `slow-open.sh:43`; `capture-window.sh:17,19`;
`run.sh:26-29`; `screenshot-lib.sh:99-106,265,344`; `appstore-capture-app-screenshots.sh:153,311`;
`generate-readme-screenshots.sh:88`).

**`launch.sh` foreign-instance policy** (the "fail loudly" requirement):
- *impostor* (our executable name, different binary path — shares our bundle id and container):
  **hard fail, exit 1, kill nothing**, print the `ps` line and the `lsregister -f` remedy.
- *other slots / stock instance*: one-line note to stderr, never fatal, never killed. Failing
  here would make concurrent agents fail on each other, defeating the change.
- Kill only own pids, then poll-until-gone instead of the blind `sleep 1` at `:25`.
- The post-launch identity check at `:47-55` becomes an **error** when slotted (a mismatch can
  only mean LaunchServices resolved our bundle id to a stale copy), and stays a warning unslotted.

**Window/capture becomes PID-driven** (owner name is "Vibe" for every slot):
- `find-window.swift:16-18` — when a pid is supplied, match on pid alone and ignore owner name.
- `capture-window.sh` — pid defaults to `vibe_pid`.
- `screenshot-lib.sh:305` — match `window-stack.swift`'s pid column (`$3`) instead of `$2 == "Vibe"`.
- `backdrop.swift:141` — bundle id from `$VIBE_BUNDLE_ID` env, literal as default.
- `slow-open.sh:26` — FIFO under `$VIBE_CONTAINER`; check the container exists and say
  "launch once first" if not.
- `scripts/validate-tempo.py:40,132` and `validate-key.py:40,166` — prefer `$VIBE_BIN`, else read
  `CFBundleExecutable` from the bundle's plist via `plistlib`, else a 4-line slot fallback.

### 5. Release safety (two layers)

- **Scrub, don't reject.** Top of `scripts/release.sh` and `scripts/release-appstore.sh`:
  `export VIBE_NO_SLOT=1` and `unset VIBE_SLOT VIBE_APP VIBE_BIN VIBE_PRODUCT VIBE_BUNDLE_ID
  VIBE_DERIVED_DATA`. It must **not** fail when a slot is in the environment — every agent shell
  has `CLAUDE_CODE_SESSION_ID`, and agents legitimately cut releases.
- **Artifact assertion at the shared choke point.** `vibe_assert_stock_bundle` after the archive
  in `scripts/asc-build-lib.sh:39` (both pipelines run it), after export in `scripts/release.sh:87`,
  and after the stapler check in `scripts/github-release.sh:66`. Checks: bundle basename is
  `Vibe.app`, `CFBundleIdentifier` is stock, `CFBundleExecutable` is `Vibe`, and
  `Contents/MacOS/Vibe` is executable.
- Leave `appstore-upload-metadata.sh:25`'s hardcoded `--bundle-id` alone — the literal *is* the
  safety property.

### 6. Documentation

`.claude/skills/vibe-debug/SKILL.md` is canonical and is the most important edit: replace the
hardcoded `APP=`/`V=` snippet at `:8-17` with the resolver, and add a **Slots** section stating
the whole contract (source, override, opt-out, Debug-only, the derived names, and *"window owner
name stays 'Vibe' for every slot — match by pid, never by name"*). Update `:25` (launch policy),
`:37` (`pgrep` recipe), `:224` (capture pid default), `:276-280` (**log predicate must gain
`process ==`**, since the subsystem is shared), plus a cleanup note (slot containers accumulate;
never exercise the default-player claim from a slot build). Also `CLAUDE.md:13` (DerivedData
path). Leave `README.md` and `docs/localization.md` unslotted — a human shell has no session id.

## Verification

Two shells against **one shared checkout** (the hard case): A `VIBE_SLOT=aaaa1111`, B `VIBE_SLOT=bbbb2222`.

1. **Regression first.** `VIBE_NO_SLOT=1 scripts/vibe-env.sh` prints exactly today's literals; a
   shell with no vars set does too. Then `make build CONFIG=Debug` unslotted and diff the produced
   `Contents/Info.plist` against the current one — must be identical.
2. **Concurrent build.** `make build CONFIG=Debug` in A and B at once; both succeed; each app has
   the expected `CFBundleIdentifier` / `CFBundleExecutable`.
3. **Name isolation.** `pgrep -x Vibe-aaaa1111` → 1 pid; `pgrep -x Vibe` → **empty**. (The whole
   design rests on this; assert it explicitly.)
4. **The core proof.** Record B's pid, run `launch.sh` in A, assert B's pid is unchanged and B
   still answers `dump_state`. Repeat via `generate-readme-screenshots.sh`'s kill path.
5. **Channel isolation.** `open` a file in A; B's `dump_state` shows an empty playlist. Both
   containers exist and are distinct. Confirm A's `dump_state.app.bundleId` is A's.
6. **Window isolation.** Set different window widths in A and B; `capture-window.sh` with no pid
   in A captures A's width. `window-stack.swift | awk '$2=="Vibe"'` shows **two** rows — proving
   name matching was genuinely ambiguous and the pid switch was necessary.
7. **Foreign-instance policy.** A stock instance running → note, exit 0, both survive. A copied
   bundle running as an impostor → exit 1, nothing killed.
8. **Release safety.** `scripts/release.sh` from a slotted shell → archive contains stock
   `Vibe.app`. Then call `vibe_assert_stock_bundle` directly against a slotted app → must exit 1
   (prove the assertion can actually fire).
9. **Unslotted end-to-end.** `VIBE_NO_SLOT=1`: `make test`, `make install`, README screenshots
   all behave as before.

## Known limits

- **The Dock and menu bar read "Vibe" for every slot** — only `ps`/Activity Monitor and the
  `.app` filename disambiguate. Fixing that means either an unscopeable `CFBundleDisplayName` in
  `info.properties` or editing 30 localizations; both were judged not worth it.
- **Container and LaunchServices accumulation**: each new slot mints a container and registers a
  bundle exporting the same `com.commonwealthrecordings.cue-sheet` UTI. Harmless
  (last-writer-wins for the description; identifier matching is unaffected) but needs the
  documented cleanup.
- **A fresh slot is a fresh profile** — empty prefs, cold caches, no folder grants, zeroed
  AppStats. Better test hygiene, but tests that assumed prior state will behave differently.
- **Xcode.app IDE builds are unslotted** by construction (no shell env), so they collide with
  each other exactly as today.
- Unverified: `tell application id … to quit` against a DerivedData bundle (falls back to
  TERM/KILL, so failure is benign); whether the `xcodegen` mutex is strictly necessary (reasoned,
  not observed).

# Future: An unsandboxed direct-download Mac build

**Status: planned, not implemented (verified 2026-10-01).** Issue #125, with `sparkle-updates.md`.

Written to be executed phase by phase. Each phase builds, passes `make test`, and is verifiable on its own. Read the root `AGENTS.md`, `Vibe/Mac/App/AGENTS.md` ("Sandbox grants", "The last playlist"), `Vibe/Audio/Mac/Convert/AGENTS.md` ("Getting the output past the sandbox"), `Vibe/Audio/Metadata/FolderArt/AGENTS.md`, `Vibe/Mac/Settings/AGENTS.md`, and `Tests/AGENTS.md` first; the release scripts need the `vibe-release` skill, strings the `vibe-strings` skill, verification the `vibe-debug` and `vibe-stress` skills.

**Build `sparkle-updates.md` first.** Its Phase 1 adds the `AppStore` configuration and the `VIBE_DIRECT_DISTRIBUTION` marker this plan stands on, and an updater is what lets the data migration here (Phase 4) reach existing users without a manual download. This plan then removes the pieces that plan needs only because the direct build is sandboxed.

## The feature

- The **Mac App Store** build stays sandboxed, exactly as today.
- The **direct-download** build (Developer ID, `make release`) runs without the App Sandbox, keeping the hardened runtime and notarization.
- What a direct-download user gains:
  - No folder grants. A playlist file's entries, a sidecar cover, and a remembered playlist are readable wherever they live, with no grant panel and no Settings > Files grant list to maintain.
  - A converted FLAC always lands beside its source, never through a save panel.
  - Folder art works for every folder, not only ones with an active grant.
- What they pay: macOS's own privacy prompts (below) replace the sandbox's, and the app's data moves once, out of its container.

**Decide first whether this is wanted.** If the grant panels, the converter's fallbacks, and grant-gated folder art are not generating complaints, the sandboxed direct build with Sparkle is the cheaper product: one behavior to test, not two. This plan's standing cost is that every sandbox-sensitive change has two variants from then on.

## What assumes the sandbox today

`ENABLE_APP_SANDBOX: YES` is set on the `Vibe` target for every configuration. The code that depends on it:

- **`FolderAccessManager`** (`Vibe/Mac/App/`, about 730 lines with its grant panel): the security-scoped bookmark store, launch restoration with its deadlines and lanes, and `canReadInsideDirectory:`. Readers: `AppDelegate` (the launch order grants → drain → restore, the playlist-grant handler at `requestAccessForPlaylistFolder:`), `FolderArtResolver` (`canReadInsideDirectory:`), `MainPlayerController`, `SettingsFilesViewController` (the grant list), and `DebugInfo`.
- **`AudioFileConverter+Sandbox`** (159 lines): the three rungs that get the encoded file out of the container's tmp — plain move, related-item coordinated move, save panel.
- **Security-scope calls on plain URLs**: `PlaylistController`'s drag-out (`startAccessingSecurityScopedResource` per dragged track) and `ArtworkImageView`'s art drag. Both already tolerate a `NO` answer.
- **`+realHomeDirectory`** (`getpwuid`): correct in both modes.
- **Where state lives**: defaults, the PINCache disk caches (`NSCachesDirectory`), `LastPlaylist.m3u` and `ThemeArt/` (`NSApplicationSupportDirectory/<bundle id>/`), saved window state. Sandboxed, all of it resolves under `~/Library/Containers/com.commonwealthrecordings.Vibe/Data/`.
- **The debug channel** (`DebugUtil.h`, `DebugClient.m`): the client and the app meet in the container's tmp and rely on sharing a container. `scripts/reset-state.sh` treats the container as the whole state and says so in its header.
- **Docs and rules** that state "the app is sandboxed" as a fact: root `AGENTS.md` (the folder-art and no-private-APIs bullets), the directory docs above, `SECURITY.md`, and the website copy if it advertises the sandbox.

## Phase 1 — The sandbox becomes a per-configuration setting

Requires the `AppStore` configuration from `sparkle-updates.md` Phase 1.

- `project.yml`, `Vibe` target: `ENABLE_APP_SANDBOX` and `CODE_SIGN_ENTITLEMENTS` move under `configs`. `AppStore` and `Debug` keep the sandbox and today's entitlements; `Release` drops the sandbox and signs with a direct entitlements file that carries nothing sandbox-specific (`com.apple.security.assets.music.read-write`, `files.bookmarks.app-scope`, `ENABLE_USER_SELECTED_FILES`, and Sparkle's `network.client` and mach-lookup exceptions all mean nothing without the sandbox).
- **Debug stays sandboxed by default**, because the sandbox is the stricter mode and the one the App Store ships, and the debug channel, the stress suites, and `reset-state.sh` are built around the container. Add `SANDBOX=0` to `make build` (an `ENABLE_APP_SANDBOX=NO` plus entitlements override passed through `build.sh`) so the unsandboxed behavior is drivable by the debug channel. Without this, the shipping direct build would be the one variant nothing automated can exercise.
- A define, `VIBE_SANDBOXED=1`, set wherever the sandbox is on. It is the one answer to "is this build sandboxed"; no runtime probing of `APP_SANDBOX_CONTAINER_ID`, and never derived from `VIBE_DIRECT_DISTRIBUTION`, since a sandboxed direct Debug build is the default.
- `release.sh` preflight: the exported app's entitlements contain no `com.apple.security.app-sandbox`; `release-appstore.sh` preflight: they do.
- CI: one unsandboxed Debug build leg (`make build CONFIG=Debug SANDBOX=0`).

**Verify:** all three configurations build; `codesign -d --entitlements -` on each export shows the intended set; an unsandboxed Debug build launches and plays. Behavior is otherwise unverified until Phase 2, so nothing ships from this phase.

## Phase 2 — The sandbox code stands down when the sandbox is off

The budget is zero new files and zero new types: each item is a branch at the top of an existing method on `VIBE_SANDBOXED`, and the unsandboxed side is the trivial one.

- **`FolderAccessManager`**, unsandboxed:
  - `canReadInsideDirectory:` answers `YES`.
  - `restoreGrantedAccessWithCompletion:` completes at once with nothing to restore, so the launch order is drain → restore → empty state with no grant wait.
  - Merging a grant from an open or a drop, and persisting, are no-ops; `grantedFolders` is empty.
  - `requestAccessForPlaylistFolder:` answers `YES` without the panel. `FolderAccessManager+GrantPanel` is not compiled into the path.
  Do not delete the stored bookmarks key on an unsandboxed launch: a user who moves back to the App Store build keeps a separate container anyway, and the direct defaults never had them.
- **Settings > Files**: the granted-folders section and Add Common Folder are absent unsandboxed. Check what remains in the pane and whether it still earns a pane.
- **Converter**: no code change expected. Rung 1, the plain move, always succeeds for a writable folder; a read-only destination still falls to the panel rung, which is the right behavior. The encode's temporary file now lives in the per-user `NSTemporaryDirectory()` rather than the container's; confirm the launch sweep of `vibe-convert-<uuid>.flac` targets `NSTemporaryDirectory()` and not a container path. `convertAsksWhereToSave` keeps its meaning.
- **Folder art**: the "no active grant, leave untouched" rule answers `YES` everywhere through `canReadInsideDirectory:`. The reason behind the rule still stands in a new form: **unasked-for background work must never raise a permission panel**, and unsandboxed the panels are TCC's (Phase 3).
- **Drag-out scopes** (`PlaylistController`, `ArtworkImageView`): unchanged; `startAccessingSecurityScopedResource` answers `NO` for a plain URL and both sites already handle it.
- **`DebugInfo`**: report sandboxed or not, and the state directory in use.
- **Debug channel and tooling**, for `SANDBOX=0` builds: the client and the app share the per-user temporary directory unsandboxed, so the handoff should work as written; confirm, and fix `DebugUtil.h`'s comments and the `vibe-debug` skill's screenshot path. `reset-state.sh` already sweeps the unsandboxed paths "in case"; its header and its "only the container is expected to exist" note become wrong and are corrected, and it gains `~/Library/Application Support/<bundle id>`, which it does not list today.

**Verify**, on an unsandboxed Debug build through the debug channel: open a playlist file whose entries sit in a folder never opened before (no panel, rows play); folder art appears for a folder never granted; convert a file opened singly from Finder (FLAC lands beside it, no panel); Settings > Files shows no grant list; quit and relaunch restores the last playlist. Then the same list on a sandboxed build, to prove nothing moved. Run `make stress` and `make torture` once against the unsandboxed build.

## Phase 3 — macOS privacy prompts (TCC)

An unsandboxed app is not free of permission panels; it trades the sandbox's for the system's.

- Reading under `~/Documents`, `~/Desktop`, `~/Downloads`, a removable volume, a network volume, or iCloud Drive raises a one-time system prompt per location class, unless the access comes from the user's own act (the open panel, a drag, a Finder open). `~/Music` is expected to be unprompted; confirm on a clean user account.
- `Info.plist` gains the usage descriptions, localized through `InfoPlist.xcstrings` (the `vibe-strings` skill covers that catalog): `NSDocumentsFolderUsageDescription`, `NSDesktopFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription`. They are harmless in the sandboxed builds, so they need no per-configuration split.
- **Where a prompt can appear with no user act**, each to be walked on a clean account:
  1. Launch restore of `LastPlaylist.m3u` whose tracks live in a protected location. Acceptable: the user played those files last session, and the prompt names the folder.
  2. The deferred metadata sweep over a restored or dropped playlist. Same as 1.
  3. `FolderArtResolver` probing a directory beside a track. It only ever reads beside a file already in the playlist, so it cannot prompt for a location the playlist has not already touched; confirm.
  4. A playlist file that names entries in a different protected location than the one it was opened from. This is the case the grant panel covered; unsandboxed it becomes a system prompt, which is acceptable.
- **A denial must degrade the way an ungranted folder does today**: unreadable rows, never a hang or a retry loop. `NSURLUtil`'s distinction between missing and denied (`access(2)`'s errno) should already hold, since TCC denials surface as `EPERM`; confirm with a denied prompt.
- A denied prompt is not asked again. Decide whether a row's unreadable state should point at System Settings > Privacy & Security > Files and Folders; not in the first version unless testing shows users get stuck.

**Verify:** on a fresh macOS user account (or after `tccutil reset All com.commonwealthrecordings.Vibe`), walk the four cases with Allow and with Don't Allow, on the exported, notarized build, since TCC keys on the signature.

## Phase 4 — Move existing users' data out of the container

The risky phase. Every current direct-download user's state is in `~/Library/Containers/com.commonwealthrecordings.Vibe/Data/`; an unsandboxed build with the same bundle id reads `~/Library/Preferences`, `~/Library/Application Support`, and `~/Library/Caches`, and would launch as a fresh install. macOS migrates data *into* a container automatically but never out of one.

**First, an experiment, before any code**: sign a throwaway unsandboxed build with the Developer ID and the real bundle id, and read the existing container from it on macOS 14 or later. The system's app-data protection prompts when a process reads another app's container; a process from the same team is expected to be let through silently. If it prompts, or denies, this phase needs a different design (a migration performed by the last *sandboxed* release, exporting to a location both builds can read) and the plan is revised before going further.

Assuming the read is silent:

- One-time, at the top of launch, before `AppSettings` or any cache is touched, only when `!VIBE_SANDBOXED`, only when a marker default is absent, and only when the container exists:
  - **Defaults**: read the container's `Library/Preferences/<bundle id>.plist` and import its keys into standard defaults, skipping the stored folder-grant bookmarks.
  - **Application Support**: copy `<bundle id>/LastPlaylist.m3u` and `<bundle id>/ThemeArt/`. The last playlist is absolute paths, so it survives the move; stored themes reference `ThemeArt` by a path under the support directory, so confirm whether those references are relative or need rewriting.
  - **Caches**: do not copy. The metadata and waveform caches rebuild, and they are the bulk of the container. State this in the release notes: the first launch re-scans.
  - **Stats** (`AppStats`): wherever they are stored, they move with the defaults or the support directory; confirm which.
  - Set the marker last, so an interrupted migration reruns. The import is copy-only and idempotent.
- **The container is never deleted or modified.** A user who returns to the App Store build finds it as they left it. The two builds' states diverge from the moment of migration, in both directions, and that is accepted and documented rather than synchronized.
- It lives in `AppDelegate`, as one function. If it will not fit there without a new file, that is argued then, not assumed now.
- Tests: the import's key filter and marker logic are a host-less unit test over a fixture container directory; the end-to-end case is the real upgrade below.

**Verify:** install the current release, build up real state (settings changed from default, a custom theme with art, a playlist, a nonzero listening total, granted folders), then update to the unsandboxed build **through Sparkle** and confirm each survives, with no prompt. Repeat with no container present (a fresh install) and with the container on a machine where the user denies nothing and grants nothing.

## Phase 5 — Remove what Sparkle needed only for the sandbox

In the `Release` configuration: `SUEnableInstallerLauncherService`, the mach-lookup temporary exceptions, and `network.client` go, with `sparkle-updates.md` Phase 2's signing checks for the Installer XPC service relaxed accordingly. A sandboxed `Debug` build that still links Sparkle keeps them, or Debug stops starting the updater when sandboxed; pick the one that leaves less configuration.

Sparkle updates a sandboxed build to an unsandboxed one without special handling. The update that crosses the boundary is the one Phase 4's verification runs.

## Phase 6 — Docs, release, and rollout

- Root `AGENTS.md`: "Building" gains the sandbox column per configuration; the folder-art guarantee's last sentence is restated in terms of *permission panels* (grant or TCC), not grants; `Mac/App/AGENTS.md`, `Convert/AGENTS.md`, `FolderArt/AGENTS.md`, and `Settings/AGENTS.md` each say what their sandbox section does unsandboxed. Every `TRAP:` touched changes in both its copies.
- `SECURITY.md` and the website say which build is sandboxed.
- The `vibe-release`, `vibe-debug`, and `vibe-stress` skills: the two entitlement sets, `SANDBOX=0`, the state locations, and a release checklist line to run the Phase 2 list against both variants.
- **Roll out as its own release**, first to the `beta` channel, with nothing else risky in it, so a migration report is unambiguous.
- Release notes: what changed, that the first launch re-scans the library, and that the App Store and direct builds keep separate settings.

## Risks and traps

- **Reading the old container may prompt or fail** (Phase 4's experiment). This is the one finding that can change the plan's shape.
- **Two variants forever.** `make test` and `make test-audio` are host-less and unsandboxed already; the app-level suites (debug channel, stress, torture) run sandboxed by default. A sandbox-sensitive change must be run both ways by hand unless CI gains a second app-level leg.
- **The same bundle id in two security models.** Launch Services, the default-music-player registration, and saved window state are shared by id. Installing the App Store build over a direct one (or the reverse) swaps which state the user sees; nothing is lost, but it looks like a reset.
- **TCC keys on the code signature.** Prompts answered for an ad-hoc Debug build say nothing about the Developer ID build, and re-signing a local build re-prompts.
- **App Store leakage runs the other way too**: an unsandboxed archive uploaded to App Store Connect is rejected at validation, so the failure is loud, but the `release-appstore.sh` preflight makes it immediate.
- **Do not unsandbox Debug by default to "simplify".** The sandboxed build is the one with the traps, and it must stay the one developed against.

## Complexity report (expected)

- New source files: 0. New types: 0.
- New non-source files: one direct entitlements file (shared with `sparkle-updates.md` if that plan created it).
- Removes: Sparkle's sandbox-only keys and entitlements from the shipping direct build; the grant panel, the grant list, and the converter's fallbacks from the direct-download user's experience.
- Consolidates nothing in the source. `FolderAccessManager` and `AudioFileConverter+Sandbox` stay whole, because the App Store build needs every line. That is this feature's cost stated plainly: it adds a second mode to a subsystem without shrinking the first.

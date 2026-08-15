# The mac/iOS/shared layout — final plan

Written 2026-08-15. Supersedes the earlier draft of this document after a full validation pass:
every path, line anchor, and factual claim below was re-verified against the working tree with the
iOS merge staged. This version is written to be handed to an implementing agent as-is.

**How to use this document.** Work the phases in order; each phase is one commit to `main` and
must pass the verification gate before the next begins. Line numbers are anchors against the tree
at time of writing — re-locate with the grep given in each step rather than trusting the number.
Nothing here requires judgment calls beyond what is spelled out; where an alternative was
considered and rejected, the appendix records why, so do not relitigate placement decisions
mid-implementation.

## The endpoint

```
Vibe/
├── Common/        shared   settings, strings, prefix header, platform aliases
├── Audio/         shared   engine, FX, metadata, waveform data, analysis
│   ├── Mac/
│   │   ├── Devices/        CoreAudio HAL layer (was Audio/Devices/)
│   │   └── Convert/        FLAC encoder (was Audio/Convert/; keeps its CLAUDE.md)
│   └── iOS/                AudioSessionController, AudioPlayer+Recovery
├── System/        shared   NowPlayingController, DownloadProgressMonitor
├── Playlist/      shared   model + CUE/M3U readers
│   └── Mac/                the table UI
├── WaveformUI/    shared   renderers + morph engine
│   ├── Mac/                AudioWaveformView (+Loading)
│   └── iOS/                WaveformScrubberView
├── Util/          shared   helpers, categories; VibeWeakProxy joins here
│   ├── Mac/                AppKit helpers
│   └── iOS/                UIView+DarkMode
├── Debug/         shared   channel transport, dispatch, common verbs, invariants,
│   │                       load timing (was Debug/Shared/)
│   ├── Mac/                command table, CLI client, screenshot, health, input,
│   │   │                   settings UI, state dump, scan cores (was Debug/ top level)
│   │   └── Introspection/  the mac +Debug category headers
│   └── iOS/                DebugCommands, PlayerViewController+Debug.h
├── Mac/                    the macOS app shell: App/, MainWindow/, Menu/,
│   │                       Controls/, Settings/, About/ — moved intact,
│   │                       each keeping its own CLAUDE.md (and APPEARANCE.md)
├── iOS/                    the iOS app shell, flat: delegates, main.m, Info.plist,
│                           PlayerViewController, TrackPageCell, TrackPageGeometry,
│                           TrackListViewController, SearchViewController,
│                           FolderSession, PageWaveformPipeline
└── ThirdParty/
```

The rule this tree makes true — this exact statement replaces the layout prose in the root
`CLAUDE.md` in phase 4:

> Every directory directly under `Vibe/` except `Mac/`, `iOS/`, and `ThirdParty/` is a shared
> subsystem, listed in both targets' sources in `project.yml`. Within any subsystem, `Mac/` and
> `iOS/` are the only platform markers: a path containing `Mac` compiles only into Vibe, a path
> containing `iOS` compiles only into VibeiOS, and a path containing neither compiles into both.
> No source entry may exclude a feature-named path. `make check-layout` enforces all of it.

The rule is mechanically checkable, which is the point: prose annotations drift, a `make check-*`
gate does not. Note the rule is only *fully* true after phase 3 — phases 2 and 3 are severable
commits, but phase 4's check assumes both.

## What must survive any of this

These properties are correct today and a reorganization could silently destroy them. Preserve all
four.

- **Feature-first stays.** Work here is feature-shaped, not platform-shaped. The tree keeps a file
  next to the file it talks to; platform is the *secondary* axis, expressed one level down.
- **The directory stays the target-membership rule.** `project.yml` carries zero per-file
  excludes; every exclude is a whole subdirectory. A new file in a shared directory joins both
  targets automatically, and CI's `build-ios` job catches an AppKit leak on the next push.
- **The docs tree stays the loading tree.** Nested `CLAUDE.md` files load when you work under
  them. Every doc paragraph moved by this plan moves *to the directory whose `CLAUDE.md` loads
  where that knowledge is needed*.
- **Classes stay with their categories.** `AudioPlayer`, `AudioPlayer+Devices`, and
  `AudioPlayer+Recovery` all end up under `Audio/`. Nothing in this plan separates a class from a
  category on it by more than one platform subdirectory.

## Validation findings the plan rests on

- **Moves change no imports — verified, not assumed.** `USE_HEADERMAP` defaults on, app code has
  no `HEADER_SEARCH_PATHS` (only ThirdParty and `build/generated`), and zero `#import` statements
  outside ThirdParty carry a directory component. The cost of any move is `git mv`, a `project.yml`
  line, and prose that names the old path. The staged reorganization moved ~40 files without
  touching one import; this plan rides the same mechanics.
- **The `didFinishPlaying:` bug (phase 1) is real and reachable.** The iOS handler
  (`Vibe/iOS/PlayerViewController.m:1087`) auto-advances with no staleness guard; the mac's
  (`Vibe/MainWindow/MainPlayerController+PlayerEvents.m:138`) guards exactly this, with the race
  documented. The window is `folderSession:didOpenTracks:` (`PlayerViewController.m:933`), which
  replaces the playlist and plays *without stopping the player first*, so a natural end delivered
  in that window advances past the track the user just picked. The same file's
  `didAutoAdvanceFromTrack:` **has** the guard (line 1110) — the omission is accidental.
- **The earlier draft's rule had a hole.** "A path containing neither `Mac` nor `iOS` is compiled
  by both" is false for `Menu/`, `Controls/`, `Settings/`, `About/`, `App/`, and `MainWindow/`,
  which contain no platform word and compile into one target. The six "macOS only" annotations the
  draft promised to delete could only have been reworded. Moving the mac shell under `Vibe/Mac/`
  (phase 3) is what makes the rule true and the annotations deletable; it was measured at ~90
  renames across six whole-directory `git mv`s, 14 `project.yml` lines, and ~13 one-line prose
  references. That is why it is in scope now rather than deferred.
- XcodeGen keeps each target's `Info.plist` out of build phases on its own (the generated project
  bundles none). The `**/Info.plist` exclude on the App entry is defensive, not load-bearing —
  keep it, and whitelist it in the phase 4 check.

## Implementation ground rules

- **One phase, one commit, straight to `main`.** Messages follow the log's `prefix: summary`
  style (`fix:`, `organization:`, `doc:`). No trailers of any kind.
- **`git mv` only — no file renames.** Directory moves are free (headermap); renaming a *file*
  changes imports and is out of scope. `DebugShared.{h,m}` keeps its name at its new depth.
- **Regenerate after every `project.yml` edit**: `xcodegen generate` (or `make project`).
- **Docs move atomically with code.** A commit must not leave any `CLAUDE.md`, skill, or comment
  naming a path that no longer exists. Each phase lists its prose updates; the greps given are
  authoritative over the listed line numbers.
- **Verification gate**, after every phase:

  ```bash
  make project
  make build          # Release — what CI checks and what ships
  make test
  make analyze        # fails on any finding outside ThirdParty/
  xcodebuild -project Vibe.xcodeproj -scheme VibeiOS -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
  make check-strings check-vocabulary
  ```

- Comments follow the repo rule: terse, only what code cannot show, `TRAP:` for the hard-won ones.
  Third-party sources are never touched.

## Phase 0 — land the in-flight work

Precondition, not part of this plan's changes. At time of writing the entire iOS merge and the
`Devices/`/`Common/`/`Playlist/Mac/` reorganization are **staged but uncommitted**, and
`Vibe/Debug/Shared/DebugInvariants.{h,m}` are **untracked** — yet required by the staged
`DebugHealth.m`, so the staged tree does not build without them. If this is still true when
implementing: `git add` the two DebugInvariants files and commit the staged work as its own
commit before anything below. If it has already been committed, skip to phase 1. This document
itself (`docs/future/ios-layout-cleanup.md`) is also untracked; commit it whenever convenient.

## Phase 1 — the bug fix (independent of any move)

`fix:` commit. In `Vibe/iOS/PlayerViewController.m`, locate
`- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track` (anchor:
line 1087; grep `didFinishPlaying` if moved) and add the staleness guard as the first statement:

```objc
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track {
    // A natural end can be delivered just as the playlist is replaced —
    // folderSession:didOpenTracks: replaces and plays without stopping the
    // player first — and advancing then skips past the track the user just
    // picked. Same guard as the mac's MainPlayerController+PlayerEvents.
    if (track && ![_playlist isCurrentTrack:track]) {
        return;
    }
    if ([_playlist next]) {
    ...
```

Notes for the implementer:

- `track &&` matches the mac's shape: a nil track proceeds. `isCurrentTrack:` is the file's own
  idiom (already used at lines 1003, 1025, and 1110).
- The mac handler's stale branch also does `AppStats` bookkeeping; **do not port it** — `AppStats`
  is mac-only (`Vibe/App/`) and the iOS handler references it nowhere. A bare return is correct:
  the in-flight `playCurrentTrack` owns the UI and timer state through its own delegate callbacks.
- The gapless fallback at line ~1118 (`didAutoAdvanceFromTrack:` calling `didFinishPlaying:`)
  reaches this handler only after its own `isCurrentTrack:` guard passed, so the new guard is a
  no-op on that path — verify by reading, no code change there.
- The race is not practically reproducible on demand; verification is the gate plus review against
  the mac pattern. Run the gate anyway.

## Phase 2 — repatriate the iOS halves, unify the mac subdirectories

`organization:` commit. After this phase, `Vibe/iOS/` is purely the iOS app shell and every
shared subsystem has the same shape: shared at top, `Mac/` and/or `iOS/` below.

### 2a. Moves

Order matters only for Debug (mac files down before shared files up, to keep the tree readable in
the diff). `mkdir` new parents as needed; `git mv` handles files already staged as adds cleanly.

| # | from | to |
| --- | --- | --- |
| 1 | `Vibe/iOS/Waveform/WaveformScrubberView.{h,mm}` | `Vibe/WaveformUI/iOS/` |
| 2 | `Vibe/iOS/AudioSessionController.{h,m}` | `Vibe/Audio/iOS/` |
| 3 | `Vibe/iOS/AudioPlayer+Recovery.{h,m}` | `Vibe/Audio/iOS/` |
| 4 | `Vibe/iOS/UIView+DarkMode.{h,m}` | `Vibe/Util/iOS/` |
| 5 | `Vibe/iOS/VibeWeakProxy.{h,m}` | `Vibe/Util/` (shared — see appendix) |
| 6 | `Vibe/Audio/Devices/` (whole dir, 8 files) | `Vibe/Audio/Mac/Devices/` |
| 6 | `Vibe/Audio/Convert/` (whole dir, incl. its `CLAUDE.md`) | `Vibe/Audio/Mac/Convert/` |
| 7 | `Vibe/Debug/` top-level mac files (13: `DebugBPMScan.mm`, `DebugClient.m`, `DebugCommandTable.m`, `DebugHealth.{h,m}`, `DebugInput.m`, `DebugInternal.h`, `DebugScreenshot.m`, `DebugSettingsUI.{h,m}`, `DebugStateDump.m`, `DebugUtil.{h,m}`) | `Vibe/Debug/Mac/` |
| 7 | `Vibe/Debug/Introspection/` (whole dir, 5 files) | `Vibe/Debug/Mac/Introspection/` |
| 7 | `Vibe/Debug/Shared/*` (everything, 17 files) | `Vibe/Debug/` (top level; `Shared/` disappears) |

After the moves `Vibe/iOS/Waveform/` and `Vibe/Debug/Shared/` are empty and gone;
`FolderSession` and `PageWaveformPipeline` deliberately **stay** in `Vibe/iOS/` — the first is the
app's document-access layer (the counterpart of the mac shell's `FolderAccessManager`), the second
is pager bookkeeping with no mac analogue.

### 2b. project.yml

Every *shared* entry gets its platform exclude unconditionally — including directories with no
platform subdirectory yet (`Common`, `System`, `Playlist` on the mac side) — so a future platform
half needs zero `project.yml` edits and the phase 4 check can demand one exact shape. Excludes
that match nothing are harmless to XcodeGen.

Vibe (macOS) target — the seven shared entries become exactly:

```yaml
      - path: Vibe/Audio
        excludes: ["**/.DS_Store", "**/*.md", "iOS/**"]
      - path: Vibe/Common
        excludes: ["**/.DS_Store", "**/*.md", "iOS/**"]
      - path: Vibe/System
        excludes: ["**/.DS_Store", "**/*.md", "iOS/**"]
      - path: Vibe/Util
        excludes: ["**/.DS_Store", "**/*.md", "iOS/**"]
      - path: Vibe/WaveformUI
        excludes: ["**/.DS_Store", "**/*.md", "iOS/**"]
      - path: Vibe/Playlist
        excludes: ["**/.DS_Store", "**/*.md", "iOS/**"]
      - path: Vibe/Debug
        excludes: ["**/.DS_Store", "**/*.md", "iOS/**"]
```

(The `Vibe/Debug` entry already excludes `iOS/**`; its trailing comment about "the iOS command
table" can go. The `App`, `MainWindow`, `Menu`, `Controls`, `About`, `Settings`, and ThirdParty
entries are untouched in this phase.)

VibeiOS target — the shared entries become exactly the mirror, and the two Debug entries
(`Vibe/Debug/Shared` + `Vibe/Debug/iOS`) **collapse into one**:

```yaml
      - path: Vibe/iOS
        excludes: ["**/.DS_Store", "**/*.md"]
      - path: Vibe/Audio
        excludes: ["**/.DS_Store", "**/*.md", "Mac/**"]
      - path: Vibe/Common
        excludes: ["**/.DS_Store", "**/*.md", "Mac/**"]
      - path: Vibe/System
        excludes: ["**/.DS_Store", "**/*.md", "Mac/**"]
      - path: Vibe/Util
        excludes: ["**/.DS_Store", "**/*.md", "Mac/**"]
      - path: Vibe/Playlist
        excludes: ["**/.DS_Store", "**/*.md", "Mac/**"]
      - path: Vibe/WaveformUI
        excludes: ["**/.DS_Store", "**/*.md", "Mac/**"]
      - path: Vibe/Debug
        excludes: ["**/.DS_Store", "**/*.md", "Mac/**"]
```

The Audio entry's `Devices/**` and `Convert/**` excludes are what this replaces — that is the
whole point of move 6.

Also in this phase:

- **VibeTests**: `Vibe/Debug/Shared/AudioLoadTiming.m` → `Vibe/Debug/AudioLoadTiming.m` (anchor:
  project.yml:536; grep `AudioLoadTiming`).
- **Layout comments**: the mac block's header comment (anchor ~124–133), the iOS block's comment
  (~328–335), and the Debug comment (~363–365) describe the old shape. Rewrite them to state the
  endpoint rule briefly and point at the root `CLAUDE.md`; keep the "A NEW DIRECTORY NEEDS A NEW
  ENTRY" warning, which stays true.

### 2c. Prose

Authoritative grep (run it; fix every hit outside `docs/future/` and `ThirdParty/`):

```bash
grep -rn "Debug/Shared\|Debug/Introspection\|Audio/Devices\|Audio/Convert\|iOS/Waveform\|Vibe/iOS/AudioSessionController\|Vibe/iOS/AudioPlayer+Recovery" \
  --include='*.md' --include='*.yml' --include='*.sh' . | grep -v ThirdParty | grep -v docs/future
```

Known hits and their dispositions:

- **Root `CLAUDE.md`**: subsystem-map entries for `Audio/` ("`Devices/` is the CoreAudio HAL…"),
  `Audio/Convert/` (line 48), `WaveformUI/` ("the iOS scrubber is in `Vibe/iOS/`", line 49),
  `Vibe/iOS/` (line 57 — drop the scrubber/session/recovery clauses, now owned elsewhere), and
  `Util//About//Debug` (line 58 — `Debug/Shared/` no longer exists; Debug is now "shared at top,
  `Mac/` and `iOS/` halves"). In the boundary paragraph (line 62), delete the parenthetical
  "(`Audio/Devices/` and `Audio/Convert/` are the same rule under their own names)" — after this
  phase they are literally under `Mac/`. The *full* rewrite of that paragraph waits for phase 4.
- **`Vibe/iOS/CLAUDE.md`** — the biggest edit, and the reason the moves pay off:
  - The **`AudioSessionController`** and **`AudioPlayer+Recovery`** bullets move to
    `Vibe/Audio/CLAUDE.md` (which already documents the recovery entries at its line ~15 — merge,
    don't duplicate, and fix that line's `Vibe/iOS/AudioPlayer+Recovery` path to `Audio/iOS/`).
  - The **`WaveformScrubberView`** bullet moves to `Vibe/WaveformUI/CLAUDE.md` verbatim — it is
    renderer-contract knowledge (virtual bounds, the geometryFlipped TRAP, the envelope-bake fast
    path) that must load when someone touches a renderer.
  - The target-membership paragraph (second paragraph) is rewritten to the endpoint rule; it
    currently enumerates `Audio/Devices`, `Audio/Convert`, `Playlist/Mac`, `WaveformUI/Mac`,
    `Util/Mac`, and `Debug/Shared` by name.
  - What remains keeps at most a one-line pointer to each moved piece's new home — the repo's
    docs philosophy is single-home-plus-pointer, never duplication.
- **`Vibe/WaveformUI/CLAUDE.md`** — receives the scrubber section; grep it for `Vibe/iOS` mentions.
- **`Vibe/MainWindow/CLAUDE.md`** — `Audio/Convert/` (lines 19, 46) → `Audio/Mac/Convert/`;
  `Vibe/Debug/Introspection/` (the `+Debug.h` bullet) → `Vibe/Debug/Mac/Introspection/`.
- **`Vibe/Menu/CLAUDE.md`** — `Audio/Convert/CLAUDE.md` and `Audio/Convert/` (lines 17, 21).
- **`Vibe/Util/CLAUDE.md`** — add one line each for `iOS/UIView+DarkMode` (the NSView+DarkMode
  mirror) and `VibeWeakProxy` (shared; breaks CADisplayLink/NSTimer retain cycles; currently only
  iOS aims one).
- **`.claude/skills/vibe-debug/SKILL.md`** — line ~91 names `Vibe/Debug/Shared/DebugChannel.m` and
  `Vibe/Debug/Shared/DebugCommonVerbs.m` → `Vibe/Debug/…`; `Vibe/Debug/iOS/DebugCommands.m` is
  unchanged. Grep the whole skill for `Debug/Shared`.

## Phase 3 — the mac shell under `Vibe/Mac/`

`organization:` commit. Six whole-directory moves; nothing inside any of them changes.

### 3a. Moves

```bash
mkdir Vibe/Mac
git mv Vibe/App        Vibe/Mac/App
git mv Vibe/MainWindow Vibe/Mac/MainWindow
git mv Vibe/Menu       Vibe/Mac/Menu
git mv Vibe/Controls   Vibe/Mac/Controls
git mv Vibe/Settings   Vibe/Mac/Settings
git mv Vibe/About      Vibe/Mac/About
```

`main.m` stays at the repo root (it imports `AppDelegate.h` flat — headermap). Each directory's
`CLAUDE.md`, and `MainWindow/APPEARANCE.md`, travel inside their directories automatically.

### 3b. project.yml

All in the Vibe target and VibeTests; the VibeiOS target never names these directories.

- Six source paths: `Vibe/App` → `Vibe/Mac/App`, and likewise `MainWindow`, `Menu`, `Controls`,
  `Settings`, `About`. Excludes unchanged (the App entry keeps `**/Info.plist`). Update the
  "macOS-only." comment above them — these entries are now self-describing.
- `info: path: Vibe/App/Info.plist` → `Vibe/Mac/App/Info.plist` (anchor ~197).
- `CODE_SIGN_ENTITLEMENTS: "$(SRCROOT)/Vibe/App/Vibe.entitlements"` →
  `"$(SRCROOT)/Vibe/Mac/App/Vibe.entitlements"` (anchor ~289).
- VibeTests sources: `Vibe/App/FolderAccessManager.m`, `Vibe/App/OpenBurstCoalescer.m`, and
  `Vibe/App/OpenRequestCoordinator.m` → `Vibe/Mac/App/…` (anchors ~546–548).

### 3c. Prose

Authoritative grep:

```bash
grep -rn "Vibe/App\|Vibe/MainWindow\|Vibe/Menu\|Vibe/Controls\|Vibe/Settings\|Vibe/About" \
  --include='*.md' --include='*.yml' --include='*.sh' . | grep -v ThirdParty | grep -v build/ | grep -v docs/future
```

Known hits: root `CLAUDE.md` (subsystem-map paths — and this is where the six "macOS only"
annotations on `App/`, `MainWindow/`, `Menu/`, `Controls/`, `Settings/`, `About/` are **deleted**,
not reworded, with a new one-line `Vibe/Mac/` map entry added); `Vibe/Mac/App/CLAUDE.md`
(self-references); `Vibe/Common/CLAUDE.md` (`Vibe/Settings/`); `Vibe/Util/CLAUDE.md`
(`Vibe/App/`); `Vibe/Mac/Menu/CLAUDE.md` (`Vibe/App/`);
`.claude/skills/vibe-debug/SKILL.md` (`Vibe/Settings/CLAUDE.md`);
`scripts/appstore-generate-store-screenshots.sh` (a comment naming
`Vibe/Menu/MainMenuBuilder.m`). `Makefile`, `CONTRIBUTING.md`, and `Tests/CLAUDE.md` were
verified clean of these paths — but run the grep, not the memory of it.

## Phase 4 — enforce and document

`organization:` or `doc:` commit.

### 4a. `scripts/check-layout.sh` + `make check-layout`

A new gate in the family of `check-vocabulary.sh` (same tone: print the offending line, exit
non-zero). It asserts, against `project.yml`:

1. **Exclude whitelist.** Within every source entry of the Vibe and VibeiOS targets, each exclude
   is one of `**/.DS_Store`, `**/*.md`, `Mac/**`, `iOS/**` — plus, for ThirdParty entries only,
   the documented set (`**/*.xcprivacy`, `**/*.txt`, `**/LICENSE.MPL`, `**/PINDiskCache.m`), and
   `**/Info.plist` for app-shell entries. Anything else — any feature-named exclude — fails.
2. **Platform-word membership.** No `- path:` under the Vibe target contains `/iOS`
   (`Vibe/iOS` included); none under VibeiOS contains `/Mac`. Every shared entry (a `Vibe/<dir>`
   path present in both targets) excludes `iOS/**` in Vibe and `Mac/**` in VibeiOS — the exact
   shapes phase 2 installed.
3. **Top-level coverage.** Every directory directly under `Vibe/` on disk except `Mac`, `iOS`,
   and `ThirdParty` appears as a source path in **both** targets; `Vibe/Mac` appears only in Vibe
   and `Vibe/iOS` only in VibeiOS. This is the machine-checked form of "a new directory needs a
   new entry" *and* of the endpoint rule itself.

Implementation latitude: `project.yml` is stable two-space-indented YAML; an awk/shell state
machine over the `targets:` blocks in the existing scripts' style is fine, as is python3 stdlib —
no new dependencies. Wire it as a `check-layout` Makefile target (mirror `check-vocabulary`,
update `.PHONY`) and add a `run: make check-layout` step to the CI job in
`.github/workflows/build.yml` that runs `make check-vocabulary` (anchor ~line 159).

### 4b. Root `CLAUDE.md` rewrite

Replace the "The directory is the platform boundary" paragraph with the endpoint rule quoted at
the top of this document (adding that `make check-layout` enforces it and CI's `build-ios` job
catches AppKit leaks in shared code). Sweep the subsystem map once more: after phases 2 and 3 it
should contain **zero** "macOS only" annotations and zero platform facts not derivable from a
path. Update `Vibe/iOS/CLAUDE.md`'s membership paragraph to reference the rule rather than
restate the directory list.

## Explicitly out of scope — tracked follow-ups

- **iOS platform invariants.** `debugAppendPlatformInvariants:` is adopted only by the mac
  (`MainPlayerController+Debug.m:98` at time of writing). The iOS surface should contribute its
  audio-session state machine (interruption/route-change/media-reset verdicts) as checks. Separate
  change, after the moves settle.
- **The "async deliveries race track changes" invariant stays audit-enforced.** It is handler
  discipline, not a state predicate; `DebugInvariants.m` catches downstream symptoms only. Phase 1
  closes the one known drift; re-read both platforms' delegate handlers whenever either changes.
- **A shared player-controller layer stays unextracted.** `MainPlayerController` and
  `PlayerViewController` implementing `AudioPlayerDelegate` independently is correct — the
  protocol is the shared contract, and the controllers' bulk is genuinely platform-unique.

## Appendix — decisions and rejected alternatives

**Top-level `Mac/`, `iOS/`, `Common/` (platform-first): rejected.** It splits `AudioPlayer` from
its categories across three trees, buries the shared 40% a level down under a re-grown feature
tree, loses automatic target membership, and shatters the docs-loading tree. The phase 3 shell
move shares none of these defects: it relocates only whole, mac-only subsystems and splits
nothing shared.

**Deferring the shell move (the earlier draft's position): rejected on validation.** The draft's
own rule is unstatable without it (see findings), the measured cost is ~90 free renames plus ~27
one-line references, and the tree is already in its churn season — the iOS merge is landing now,
and a third reorganization later costs more than finishing the shape today. The phases remain
severable: stopping after phase 2 leaves a coherent tree, just with a two-part rule and six prose
annotations that phase 4's check cannot then cover.

**`VibeWeakProxy` to `Util/iOS/` instead of shared `Util/`: rejected, narrowly.** Its only caller
aims a `CADisplayLink`, but the class is pure Foundation — placement is by content, and parking a
platform-free class in a platform directory miscategorizes it by the tree's own rule. Cost of
sharing: ~40 lines of dead code in the mac binary, linker-stripped. If this is relitigated, it is
a 30-second `git mv` either way; do not let it block the phase.

**Keeping `Audio/Devices/` and `Audio/Convert/` as feature-named mac subdirs (whitelisting them
in the check): rejected.** It reintroduces per-case memorization — `Audio/` would hold three
platform subdirectories of which two are secretly mac — and the check gains a whitelist that is
just the old prose in YAML form. Flattening both into one `Audio/Mac/` was also rejected:
`Convert/` keeps its own `CLAUDE.md` as a loadable unit, and the two file sets are genuinely
distinct. `Audio/Mac/Devices/` keeps both dimensions readable: `Mac` says where it compiles,
`Devices` says what it is.

**Flattening `Debug/Mac/Introspection/`: rejected.** Symmetry with the flat `Debug/iOS/` argued
for it, but grouping earns its keep at the mac side's ~15 files, not the iOS side's 3. Revisit
only if the mac side shrinks.

**Renaming `DebugShared.{h,m}`: rejected.** The name predates the `Shared/` directory and file
renames touch imports; moves are free, renames are not. Out of scope.

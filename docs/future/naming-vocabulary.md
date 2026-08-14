# Future: one word per coordination pattern

Written 2026-08-14, from a survey of every use of the coordination vocabulary (`generation`, `claim`, `waiter`, `token`, `sequence`, `snapshot`, `intent`) across `Vibe/`. The finding: the codebase implements five coordination patterns *consistently*, but the words naming them collide — the same word means different things in different files, and the single worst offender is a bare ivar name. The fix is a small glossary plus three mechanical renames. No behavior changes anywhere in this plan.

## The five patterns (what the words are supposed to mean)

1. **Staleness counter** — a monotonic integer stamped onto async work; on completion, a mismatch means "superseded, drop it." This is `generation` in `AudioPlayer` (`_generation`, `_engineIdleStopGeneration`), `AudioFX` (`_rampGeneration`, `_lowKillRampGeneration`, `_reverbSendRampGeneration`), both caches (`_cacheGeneration` in `AudioWaveformCache.mm` and `AudioTrackMetadataCache.m`), `OpenRequestCoordinator`, `AudioTrackArtwork`, and `SettingsAdvancedViewController`.
2. **Single-flight ownership** — N callers want the same expensive work done once; one becomes the *owner*, the rest become *waiters* who receive the result in a fan-out. `MetadataParseCoordinator`'s `claim` / `MetadataParseClaimRole{Owner,Waiter,AlreadyOwner}`.
3. **Currency handle** — an opaque object a caller holds to later prove "my request is still the live one": `OpenRequestToken`, which internally carries a generation plus a `sequence` for delivery ordering.
4. **Desired end state** — the user-facing state a request must land in regardless of retargeting: `VibePendingPlaybackIntent` (position + paused).
5. **Immutable cross-thread copy** — `snapshot`. Already used with exactly one meaning everywhere (waveform progressive snapshots, `FolderAccessManager` entry snapshots, the duration snapshot in `MainPlayerController`).

## The collisions this plan removes

- `claim` means both the parse single-flight and `DefaultAppClaim` in Settings (claiming the default-music-player role from Launch Services).
- `AudioPlayer`'s bare `_generation` sits beside `_engineIdleStopGeneration` and `_rampGeneration`, which do say what they guard; the unnamed one reads as something special when it is just the player-node segment-completion generation.
- Not renamed, but named as accepted: `waiter` also appears as `VibeRestorationWaiter` in `FolderAccessManager` (same "parked callback, delivered once" meaning — benign); `token` also appears as the debug CLI's lexer tokens and Darwin `notify_register` tokens (standard vocabulary in both domains); `Coordinator` names three different contracts (`PlaybackRequestCoordinator` = request identity, `MetadataParseCoordinator` = single-flight, `OpenRequestCoordinator` = ordered delivery). Renaming the coordinator classes was considered and rejected: header/test churn for a smaller clarity gain than the glossary provides.

## The glossary (this is the content step 3 adds to CLAUDE.md)

| Term | Means exactly | Never used for |
| --- | --- | --- |
| `generation` | staleness counter; always spelled `<protectedThing>Generation`, never bare | batch ordering, handles |
| `claim` | single-flight ownership of shared work (roles: owner, waiter) | OS-level role registration |
| `waiter` | a parked callback delivered exactly once when its event settles | polling loops |
| `token` | opaque handle proving a request is still current (CLI lexer "tokens" and Darwin notify tokens are separate, standard usages) | counters |
| `intent` | the desired end state a request must land in | the request itself |
| `snapshot` | immutable copy handed across threads | live references |
| `sequence` | delivery order within one generation | anything else |

## Step 1: `AudioPlayer._generation` → `_segmentGeneration`

Pure mechanical rename, one file: 17 occurrences of `_generation` across `Vibe/Audio/AudioPlayer.m` (the ivar declaration, every bump and read, and the comment at the `_stateLock` documentation block near line 107). Do **not** touch `_engineIdleStopGeneration` (already well named) or `_rampGeneration` (that one is `AudioFX`'s, mentioned in AudioPlayer only around the shared fade stepper). The method `segmentDidCompleteWithGeneration:` already uses the segment word — that is where the new name comes from. No header changes: the ivar is file-private. No test references exist (verified by grep at writing time; re-verify).

Careful-match warning: `Tests/` compiles some player sources directly — grep the whole repo for `_generation` before and after, not just `Vibe/Audio/`, and expect the only surviving bare `_generation` hits to be `OpenRequestCoordinator.m`'s (which is fine as an implementation detail of a one-counter class, but prefixing it `_openGeneration` while there costs nothing and completes the rule).

## Step 2: `DefaultAppClaim` → `DefaultAppRegistration`

Frees `claim` to mean single-flight exclusively. Surfaces (verified by grep at writing time):

- `Vibe/Settings/DefaultAppClaim.h` and `.m` — rename the files themselves plus the class, and any `defaultAppClaim`-derived symbol inside.
- `Vibe/Settings/SettingsGeneralViewController.m` — the import and call sites.
- `Vibe/Common/DocumentTypes.h` — one reference.

Because two files are renamed, regenerate the project afterwards (`xcodegen generate`); XcodeGen globs the directory, so no `project.yml` edit is needed. Do **not** touch the user-facing string `STR_SETTINGS_DEFAULT_PLAYER_SET` in `VibeStrings.h` — its translator comment uses the word "claims" as ordinary English, which is fine and not part of this vocabulary.

## Step 3: add a Vocabulary section to root `CLAUDE.md`

Place it directly after the "Cross-directory invariants" section, titled `### Vocabulary`, containing one sentence of framing ("One word per coordination pattern; a new synonym is a bug:") followed by the glossary table above. Keep the table exactly as written here, including the two parenthetical carve-outs for `token`.

## Verification

```bash
make build CONFIG=Debug && make test
```

Then confirm the rule holds: `grep -rn "_generation\b" Vibe --include='*.m' --include='*.mm' | grep -v ThirdParty` should return nothing (every generation counter now carries a prefix), and `grep -rn "DefaultAppClaim" Vibe Tests` should return nothing. No strings work is involved (`make strings` not needed — no `STR_*` or catalog changes), and no behavior change means no debug-channel verification is needed.

## Explicitly out of scope

- Renaming the three `*Coordinator` classes (rejected above).
- `snapshot`, `waiter`, `intent`, `sequence`, and the debug lexer's `token`s — each already has one meaning; leave every one of them alone.
- The straggler-deadline behavior in `OpenRequestCoordinator` — that is audit finding A1/A2 territory, a separate change; this plan must not modify that file beyond the optional `_openGeneration` prefix in step 1.

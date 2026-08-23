# Fix folder-access coverage on case-sensitive volumes (macOS)

Written 2026-08-23. Planned, not implemented. The file:line anchors are against
`bd2b0dc` with an uncommitted working tree; re-check them before implementation.

## Outcome

An active sandbox grant must authorize background reads according to the case
semantics of the volume holding the granted root:

- on a case-sensitive volume, `/Volumes/Library/Albums` must **not** authorize
  `/Volumes/Library/albums`;
- on a case-insensitive volume, those spellings may describe the same directory
  and must continue to match;
- when the volume's semantics cannot be established, Vibe must compare exactly.

The read check stays a pure lookup over an immutable runtime snapshot. It must not
stat, canonicalize, resolve, mount or otherwise touch the candidate directory.

This is a macOS-only fix. It changes no bookmark-store schema, no setting, no UI
string and no iOS behavior.

## The bug

`FolderAccessManager.canReadInsideDirectory:` is the authorization gate used by
`FolderArtResolver` before it probes a directory (`FolderArtResolver.m:103-106`).
It currently reads `activePathSnapshot` and calls
`readablePath:isCoveredByAnyOf:` (`FolderAccessManager.m:177-182`). That helper
always folds case (`:625-650`).

On a case-sensitive volume, these are distinct siblings:

```text
/Volumes/CaseSensitive/Albums
/Volumes/CaseSensitive/albums
```

If the first is actively granted, the current comparison returns YES for the
second. `FolderArtResolver` is then told that it may perform an unasked-for
background read where no matching directory scope exists. The sandbox normally
denies that read, but the authorization decision is still false, the I/O was
avoidable, and the resolver can fail to discover art that should remain unsettled
until a real grant arrives.

The existing explanation for folding case is valid only for **restoration
matching**. A stored bookmark path may be compared with an uncanonicalized URL
from Launch Services. A loose match there can promote or wait for an unrelated
case-variant restoration, but it grants no authority and is bounded by the
two-second restoration deadline. The same loose rule must not be reused for an
actual read decision.

## Why canonical paths alone are insufficient

Use the OS's canonical spelling whenever Vibe activates a grant. That should be
part of this fix, but it is not the whole fix.

The later candidate passed to `canReadInsideDirectory:` can come from a playlist,
Launch Services, argv or a pasteboard. `URLByStandardizingPath` does not recover
the filesystem's stored case. Exact comparison against a canonical grant would
therefore reject a legitimate differently-cased spelling on a case-insensitive
volume.

Canonicalizing every candidate would answer that question, but it would require
filesystem access in the authorization predicate itself. That is circular: the
predicate exists so background work can decide not to touch an unauthorized
directory. It would also put a potentially blocking metadata lookup back on hot
paths involving file-provider, network and unavailable volumes.

The correct split is:

1. While Vibe already has authority and is already doing background filesystem
   work to activate a grant, capture the OS-canonical root and the volume's case
   semantics.
2. Publish those facts as immutable runtime state.
3. Compare later candidate strings without filesystem I/O.

## Decisions

| Question | Decision |
| --- | --- |
| Where is case sensitivity obtained? | Once per grant activation, off-main, from `NSURLVolumeSupportsCaseSensitiveNamesKey`. |
| Is it persisted? | No. It is runtime state and is recomputed after every bookmark resolution or new Powerbox grant. |
| Why not persist it? | A bookmark can later resolve on a different or reformatted volume; the volume is the authority. |
| What path is stored? | `NSURLCanonicalPathKey` when available, otherwise the resolved/granted URL's path. |
| What if either resource value fails? | Keep the best path available and use exact comparison. False negatives are recoverable; false authorization is not. |
| Does `canReadInsideDirectory:` perform I/O? | Never. It reads one immutable atomic snapshot and does string comparisons only. |
| What happens to restoration matching? | Its deliberately loose, non-authoritative comparison remains case-insensitive. |
| What about `~/Music`? | Treat the standing entitlement as a coverage root with the same runtime case metadata, obtained once off-main from the real home volume. |
| Does the defaults schema change? | No. Persist only `path` and `bookmark`, exactly as today. |

`NSURLVolumeSupportsCasePreservedNamesKey` is not the decision. A volume may
preserve spelling while still comparing names without case. The required key is
the one that reports whether names are case-sensitive.

## Required guarantees

1. **Only a live scope authorizes reads.** A stored or resolving bookmark remains
   visible but contributes no read-coverage root.
2. **Read coverage follows the granted root's volume semantics.** Exact on a
   case-sensitive or unknown volume; folded only when the OS positively reports
   a case-insensitive volume.
3. **Authorization costs no I/O.** The any-thread
   `canReadInsideDirectory:` contract remains true.
4. **Restoration matching is not authorization.** It may remain loose because its
   only effect is scheduling a bounded wait or promotion.
5. **Canonical duplicate detection stays exact.** `noteOpenedURLs:` compares
   canonical on-disk spellings so two case-distinct directories on a
   case-sensitive volume may each receive the bookmark they need.
6. **The active snapshot is coherent.** A reader must not observe new paths with
   old case modes or the reverse.
7. **Unknown means exact.** A failed resource-property lookup must never broaden
   authority.
8. **No persisted migration.** Existing bookmark rows restore as before and gain
   runtime coverage metadata only after their scopes start.

## Part 1 — Make the three coverage questions explicit

Today two helpers describe three different questions. Split the semantics before
changing state representation.

### 1.1 Canonical duplicate coverage

Keep `+path:isCoveredByAnyOf:` and `VibePathIsUnderFolder` for the auto-add and
Settings duplicate checks. Both operands are canonical at those call sites, so
the comparison remains exact. This is what permits both `Albums` and `albums` to
be granted on a case-sensitive volume.

### 1.2 Loose restoration matching

Keep a clearly named private helper for matching an uncanonicalized incoming URL
against an inactive stored restoration. `VibeURLIsCoveredByPath` currently fills
that role at `FolderAccessManager.m:171-175`, and is used only while choosing or
waiting for restorations (`:377-443`).

Rename it if needed so the absence of authority is obvious, for example:

```objc
static BOOL VibeUncanonicalURLMayBeUnderStoredPath(NSURL *url,
                                                   NSString *storedPath);
```

It may continue to call `VibeUncanonicalPathIsUnderFolder`. Do not feed its
answer to folder art or any other disk reader.

### 1.3 Active read coverage

Replace public `+readablePath:isCoveredByAnyOf:` with a rule that takes the
comparison mode belonging to one active root. The pure seam belongs in
`FolderAccessRules.h`, beside the two existing path decisions:

```objc
static inline BOOL VibePathIsUnderFolderRespectingCase(
        NSString *path, NSString *root, BOOL foldsCase) {
    return foldsCase
            ? VibeUncanonicalPathIsUnderFolder(path, root)
            : VibePathIsUnderFolder(path, root);
}
```

The boolean name must describe behavior (`foldsCase`), not a negated volume
property such as `notCaseSensitive`. A missing volume answer is converted to
`foldsCase == NO` before a coverage root is created.

Delete `+readablePath:isCoveredByAnyOf:` from `FolderAccessManager.h`. Its string
array cannot represent the information required to answer correctly, and leaving
it available invites a future caller to reintroduce the bug.

## Part 2 — Publish one immutable active-coverage snapshot

`activePathSnapshot` is currently an atomic array of strings
(`FolderAccessManager.m:86-90`). Replace it with one immutable snapshot object so
paths and comparison modes cannot drift across separate atomic assignments.

Private types in `FolderAccessManager.m` are sufficient; this does not need a new
public class or a fourth coordinator.

```objc
@interface VibeFolderCoverageRoot : NSObject
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) BOOL foldsCase;
@end

@interface VibeFolderAccessSnapshot : NSObject
@property (nonatomic, readonly, copy)
        NSArray<VibeFolderCoverageRoot *> *activeRoots;
@property (nonatomic, readonly, copy) NSArray<NSString *> *activePaths;
@property (nonatomic, readonly) VibeFolderCoverageRoot *musicRoot;
@end
```

The manager holds one `atomic, strong` snapshot property. The snapshot and roots
are immutable after initialization, so an any-thread reader needs only one atomic
object load and ordinary immutable reads.

`activePaths` deliberately excludes the standing Music entitlement, matching the
current `activePathSnapshot`. Existing canonical duplicate helpers already apply
the Music rule separately. Keeping both projections inside one snapshot avoids
parallel mutable state while preserving those call sites.

Rename `publishActivePaths` (`FolderAccessManager.m:716-724`) to
`publishActiveCoverage`. It constructs every active root from main-confined
entries and atomically replaces the whole snapshot. Update all existing publish
sites: restored merge, Powerbox merge and removal.

## Part 3 — Capture canonical path and case semantics during activation

### 3.1 One resource-value read

Add a small background-only helper that asks the active URL for both values in
one resource-value request:

- `NSURLCanonicalPathKey`
- `NSURLVolumeSupportsCaseSensitiveNamesKey`

Its result is:

```text
canonicalPath = canonical value, or url.path on failure
foldsCase     = (supportsCaseSensitiveNames == NO), only when the NSNumber exists
foldsCase     = NO when the property is missing or the lookup fails
```

The helper must never be called on main. Log a failed volume-property lookup once
per activation at debug or warning level, stating that exact comparison is the
fallback. Do not retry from `canReadInsideDirectory:`.

### 3.2 New Powerbox/open/drop grants

`noteOpenedURLs:` already runs `fileExistsAtPath:`, asks for
`NSURLCanonicalPathKey`, and creates a bookmark on a utility worker
(`FolderAccessManager.m:493-543`). Extend that existing background work rather
than adding a second probe:

1. Obtain canonical path and `foldsCase` together.
2. Use the canonical path for the exact duplicate check.
3. Include `foldsCase` in the runtime addition dictionary.
4. In `mergeAdditions:`, place it on the active entry under a runtime-only key.

The key must be stripped by persistence, like `accessedURL` and
`powerboxActive`. `persist` at `:689-695` must continue writing only `path` and
`bookmark`.

If an old test or defensive caller gives `mergeAdditions:` an addition without
the runtime key, treat it as exact. Do not interpret a missing value as
case-insensitive.

### 3.3 Restored bookmarks

`resolveStoredEntry:` runs in the bounded restoration scheduler and starts the
security scope before returning (`FolderAccessManager.m:315-354`). Once
`startAccessingSecurityScopedResource` succeeds:

1. Ask that resolved URL for canonical path and volume semantics.
2. Return those runtime facts with the accessed URL and refreshed bookmark.
3. In `mergeRestoredURL:...`, update the entry path to the canonical path when
   available and install `foldsCase` before publishing the snapshot.
4. Persist only if the canonical path or bookmark changed; never persist the
   case-mode bit.

The query remains within the restoration's existing bounded worker slot. It must
not be moved into `mergeRestoredURL:...`, which runs on main.

If metadata lookup fails after the scope starts, the grant remains active with
exact comparison. Do not downgrade the row to Unavailable merely because an
optional volume property was unavailable.

### 3.4 The standing `~/Music` entitlement

`musicRoot` currently derives the real on-disk home through `getpwuid`, avoiding
the sandbox-container home trap (`FolderAccessManager.m:602-660`). Preserve that
path rule.

The Music root also needs a runtime comparison mode. Resolve the case semantics
from the real home directory's volume—not by probing every candidate under
Music—once on the existing bounded utility restoration queue. Schedule this
small operation before the stored bookmark restorations so it cannot sit behind
three dead mounts.

Initial state is a Music root with exact comparison. When the background answer
lands on main:

1. replace the Music root in a newly published snapshot;
2. post the existing coalesced
   `FolderAccessManagerDidChangeNotification` if its comparison mode changed.

That notification already causes `MainPlayerController` to invalidate folder-art
answers settled without a grant. A differently-cased Music URL denied during the
brief exact fallback can therefore be reconsidered without polling.

This Music metadata operation must not hold up the launch-restoration completion
or its two-second deadline. Exact matching is already a safe temporary answer.

## Part 4 — Route callers through the correct rule

### 4.1 `canReadInsideDirectory:`

Read one `VibeFolderAccessSnapshot` and test the alias-free candidate against:

1. each active root using that root's `foldsCase` value;
2. the standing Music root using its own value.

Return immediately on a match. No URL construction, resource-value lookup, stat,
symlink resolution or main-thread hop is allowed here.

The `/private` and data-volume firmlink normalization in `VibeAliasFreePath`
remains string-only and applies to both operands before the case-aware rule.

### 4.2 `hasActiveAccessForURL:`

Use the same volume-aware active snapshot as
`canReadInsideDirectory:`. Although this method participates in restoration
waiting, its name asks whether a **live** scope covers the URL; it should not
claim that a case-distinct sibling is active.

The following loose step remains separate: if no active root covers the URL,
`hasEligibleRestorationCoveringURL:` may loosely match a stored restoration and
wait up to the existing deadline. On a case-sensitive sibling that can cause an
unnecessary bounded wait, but never false authorization. That is the exact
tradeoff the existing documentation intended.

### 4.3 Duplicate and reactivation checks

Keep these exact because their inputs are canonical:

- the first duplicate check in `noteOpenedURLs:`;
- the race re-check in `mergeAdditions:`;
- `inactiveEntryForDirectory:`;
- Settings' “Add Common Folder” enablement.

Recheck that each new-grant path has passed through the activation metadata
helper before reaching those comparisons. Do not make these checks
volume-insensitive: on a case-sensitive volume, doing so would suppress the
second bookmark that a distinct sibling requires.

## Part 5 — Tests

All automated coverage belongs in `Tests/FolderAccessCoverageTests.m`. The suite
is host-less, so test comparison decisions with injected runtime facts rather
than depending on the developer's startup volume format.

### 5.1 Pure rule tests

Replace `testReadCoverageFoldsCaseWhereTheAddCheckDoesNot`, which currently locks
in the bug, with explicit mode tests:

1. exact mode accepts an exact root and descendant;
2. exact mode rejects a root and descendant whose component case differs;
3. folded mode accepts the differently-cased spelling;
4. both modes reject prefix siblings such as `AlbumsOld`;
5. both modes preserve `/private` and data-volume firmlink equivalence;
6. the unknown/fallback construction selects exact mode.

### 5.2 Manager authorization tests

Use `mergeAdditions:` to activate deterministic fake entries:

1. a case-sensitive active grant for `.../Albums` makes
   `canReadInsideDirectory:.../Albums/Disc 1` return YES;
2. the same grant makes `.../albums/Disc 1` return NO;
3. a case-insensitive active grant makes the differently-cased descendant return
   YES;
4. an active addition with no case metadata defaults to exact;
5. an inactive stored bookmark still returns NO regardless of any stored path or
   test metadata.

Give each test its own defaults save/restore cleanup, following the existing
bookmark tests.

### 5.3 Restoration-flow tests

Extend `BlockingFolderAccessManager`'s fake resolved result so a test can provide
the runtime comparison mode. Verify:

1. the mode is not active before restoration settles;
2. it becomes active atomically with the resolved path;
3. a missing mode becomes exact;
4. removal publishes a snapshot with neither the path nor its mode;
5. reactivation racing an old restoration cannot overwrite the new grant's mode.

Existing restoration concurrency, promotion and deadline tests must remain
unchanged in behavior.

### 5.4 Persistence test

Activate a folded-case grant, then inspect `VibeGrantedFolders` in defaults. The
stored row must contain only `path` and `bookmark`. Recreate a manager from that
store and verify it authorizes nothing until restoration starts the scope and
recomputes runtime metadata.

### 5.5 Manual case-sensitive-volume verification

Use a temporary case-sensitive APFS disk image; do not assume the development
machine's startup volume supplies the edge case.

1. Mount the image and create sibling directories `Albums` and `albums`.
2. Put a playable test file and cover image in each.
3. Add only `Albums` in Settings > Files.
4. Verify a track under `Albums` may use its folder cover.
5. Open the individual track under `albums` without granting that directory.
   Verify Vibe does not treat the `Albums` grant as folder-read authority and does
   not install `albums`' cover.
6. Add `albums` explicitly. Verify the grant notification re-arms folder art and
   its cover appears.
7. Relaunch. Verify both bookmarks restore independently and retain their correct
   behavior after runtime case metadata is recomputed.
8. Repeat the differently-cased-input check on the normal case-insensitive startup
   volume and verify legitimate coverage still succeeds.

Use the repository's generated test audio if fixtures are missing. Do not commit
the disk image or its contents.

## Part 6 — Documentation changes

Update these descriptions in the same change as the code:

- `Vibe/Mac/App/CLAUDE.md` — replace the “coverage has two spellings” trap with
  the three-question split: exact canonical duplicate detection, loose inactive
  restoration matching, and volume-aware live authorization.
- `Vibe/Mac/App/FolderAccessManager.h` — document the immutable runtime coverage
  snapshot behavior and remove the obsolete public readable-path helper.
- `Vibe/Mac/App/FolderAccessRules.h` — explain that folded comparison is a mode
  supplied by a positively identified case-insensitive volume, not a universal
  read rule.
- `Tests/FolderAccessCoverageTests.m` — remove comments saying every read folds
  case and name the volume mode in each test.

The root folder-art guarantee already says background work requires an active
grant and does not need broader wording. No localization or string-catalog update
is required.

## Implementation order

1. Add the pure case-aware decision to `FolderAccessRules.h` and replace the test
   that currently codifies universal folding.
2. Add the immutable private root/snapshot types and publish an exact-only
   snapshot with current paths. Keep behavior compiling before adding metadata.
3. Switch `canReadInsideDirectory:` and `hasActiveAccessForURL:` to the snapshot;
   preserve the loose restoration helper separately.
4. Extend new-grant background metadata collection with canonical path and volume
   case semantics.
5. Extend restored-bookmark results and merge with the same runtime metadata.
6. Add the asynchronous standing-Music volume result and notification edge.
7. Add manager, restoration and persistence tests.
8. Update directory documentation and public comments.
9. Run automated checks, then perform the case-sensitive disk-image smoke test.

Each numbered step should leave exact comparison as the fallback. At no
intermediate point should a missing case mode broaden access.

## Files expected to change

- `Vibe/Mac/App/FolderAccessRules.h`
- `Vibe/Mac/App/FolderAccessManager.h`
- `Vibe/Mac/App/FolderAccessManager.m`
- `Vibe/Mac/App/FolderAccessManagerInternal.h` only if the test seam needs an
  additional declaration
- `Vibe/Mac/App/CLAUDE.md`
- `Tests/FolderAccessCoverageTests.m`

No new production source file and no `project.yml` edit should be necessary.

## Verification commands

```bash
make test
make test-summary
make analyze CONFIG=Release
make build CONFIG=Release
make check-layout
make check-vocabulary
```

`make check-strings` is not required unless implementation unexpectedly changes
user-facing copy. The implementation should not do so.

## Acceptance criteria

- A live grant never covers a case-variant sibling on a case-sensitive volume.
- A differently-cased spelling of the same path remains covered on a volume the
  OS positively identifies as case-insensitive.
- Exact spelling remains covered when volume metadata is unavailable.
- `canReadInsideDirectory:` performs no filesystem access and remains callable
  from any thread.
- Inactive, failed and still-restoring bookmarks authorize nothing.
- Loose restoration matching can affect only promotion/waiting and remains under
  the existing two-second deadline.
- New grants and restored grants publish path and case mode atomically.
- Runtime case metadata is absent from `NSUserDefaults`.
- The standing Music entitlement follows its home volume's semantics without a
  main-thread probe.
- Folder-art results denied before a grant or Music-mode update are reconsidered
  through the existing grant-change notification.
- All existing folder restoration concurrency, prioritization and reactivation
  tests continue to pass.
- Release analysis and the macOS build are clean.

## Non-goals

- Redesigning bookmark persistence.
- Canonicalizing every track or playlist URL.
- Replacing path coverage with inode ancestry or parent-directory walks.
- Resolving arbitrary symlinks during authorization.
- Changing the two-second restoration deadline or worker allocation.
- Changing folder-art precedence or cache policy.
- Adding UI that exposes volume format or case sensitivity.
- Changing iOS folder-session behavior.

## Rollback

The change has no persisted migration. If runtime coverage proves problematic,
reverting the code restores the previous comparison behavior; existing bookmark
rows remain readable because their stored representation never changed. Do not
roll back by persisting the case bit or by canonicalizing candidates inside
`canReadInsideDirectory:`—both would create new state or blocking behavior that
outlives the original fix.

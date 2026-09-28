# Bug: a live grant authorizes its case-variant sibling on a case-sensitive volume

**Status: unfixed (verified 2026-09-27). Severity: low.**

## Outcome

A live grant authorizes background reads by the case semantics of the volume holding its root: on a case-sensitive volume `/Volumes/X/Albums` does not cover `/Volumes/X/albums`; on a case-insensitive one it does; when the semantics are unknown, the comparison is exact. `canReadInsideDirectory:` stays a pure, any-thread lookup. macOS only; no bookmark schema, setting, string, or iOS change.

## The bug

`FolderAccessManager.canReadInsideDirectory:`, which `FolderArtResolver` asks before probing a directory, checks `activePathSnapshot` and the standing `~/Music` root through `+readablePath:isCoveredByAnyOf:`, which always folds case; `hasActiveAccessForURL:` shares it. With `Albums` granted on a case-sensitive volume, `albums` answers YES: the resolver makes an unasked-for read the sandbox then denies. `Tests/FolderAccessCoverageTests.m` `testReadCoverageFoldsCaseWhereTheAddCheckDoesNot` locks the bug in.

Folding is right only for **restoration matching** (`VibeURLIsCoveredByPath`): an uncanonicalized Launch Services URL against a stored path, where a loose match only schedules a wait or promotion under the two-second deadline and grants nothing. It must not decide a read.

## Why not canonicalize the candidate

A candidate comes from a playlist, Launch Services, argv, or a pasteboard, and `URLByStandardizingPath` keeps the caller's case, so exact comparison alone would refuse a legitimate spelling on a case-insensitive volume. Canonicalizing it means I/O inside the predicate whose job is to let background work avoid touching an unauthorized directory, and a blocking lookup on file-provider, network, and dead volumes. **The predicate does no I/O.** The facts are captured while Vibe already holds the scope and is already off main activating it, then compared as strings.

## Decisions

| Question | Decision |
| --- | --- |
| Source of case sensitivity | `NSURLVolumeSupportsCaseSensitiveNamesKey`, once per grant activation, off main. Not `…CasePreservedNamesKey`: preserving spelling says nothing about comparing it. |
| Path kept | `NSURLCanonicalPathKey` when available, otherwise the granted or resolved URL's path. |
| Lookup fails or key missing | `foldsCase = NO`. **Unknown means exact**: a false refusal is recoverable, a false authorization is not. |
| Persisted? | No. A bookmark can resolve onto a different or reformatted volume. `persist` keeps writing only `path` and `bookmark`. |
| Read check I/O | None. One atomic load, then string comparisons. |
| Restoration matching | Stays loose; it authorizes nothing. |

## Required guarantees

1. Only a live scope authorizes; a stored or restoring row covers nothing.
2. Read coverage is exact on a case-sensitive or unknown volume, folded only where the OS positively reports case-insensitive.
3. `canReadInsideDirectory:` costs no I/O and stays any-thread.
4. Canonical duplicate detection stays exact, so `Albums` and `albums` on a case-sensitive volume each get a bookmark.
5. One atomic load yields a coherent paths-with-modes view.
6. Nothing new is persisted; a restored row gains its mode only once its scope starts.

## The fix

**Three coverage questions, three rules.** Today two helpers answer three questions.

- *Exact canonical duplicate:* `+path:isCoveredByAnyOf:` over `VibePathIsUnderFolder`, unchanged, for `noteOpenedURLs:`, the `mergeAdditions:` race recheck, `inactiveEntryForDirectory:`, and Settings' `folderGranted:in:`. Both operands are canonical there.
- *Loose restoration matching:* `VibeURLIsCoveredByPath`, unchanged in behavior, renamed (e.g. `VibeUncanonicalURLMayBeUnderStoredPath`) so its lack of authority is plain. Its answer never reaches a disk reader.
- *Volume-aware live authorization:* `VibePathIsUnderFolderRespectingCase(path, root, foldsCase)` in `FolderAccessRules.h`, choosing between the two existing rules over `VibeAliasFreePath` operands. `canReadInsideDirectory:` and `hasActiveAccessForURL:` use it. Delete `+readablePath:isCoveredByAnyOf:` and the private `caseInsensitive:` variant: a string array cannot carry the mode.

**The snapshot, with no new type.** `activePathSnapshot` becomes `activeCoverageSnapshot`, one `atomic, copy` immutable `NSArray` of `@{kEntryPathKey: path, kEntryFoldsCaseKey: @(foldsCase)}` rows, published by `publishActiveCoverage` (replacing `publishActivePaths`) from `_entries` at its three existing call sites. A row is a two-field projection of an entry, and entries are already dictionaries under those keys, so a class would duplicate the file's own representation. Path and mode share a row, so one load is coherent; the duplicate checks take their strings from the same load with `valueForKey:kEntryPathKey`. `~/Music` stays outside the array as today: its path is fixed (`+musicRoot`) and its mode is a separate `atomic` BOOL, `musicFoldsCase`, initially NO. No reader needs it to agree with the grant rows.

**Capture once per activation, off main.** One background-only helper asks the active URL for `NSURLCanonicalPathKey` and `NSURLVolumeSupportsCaseSensitiveNamesKey` in a single `resourceValuesForKeys:` call and logs a failed volume lookup once, naming exact as the fallback.

- *New grants:* `noteOpenedURLs:`'s existing utility worker calls it in place of its canonical-path lookup and puts `kEntryFoldsCaseKey` in the addition; `mergeAdditions:` copies it onto the entry, and a missing value is exact.
- *Restored grants:* `resolveStoredEntry:` calls it after `startAccessingSecurityScopedResource` succeeds, inside the restoration's bounded worker slot, and returns path and mode with the URL and bookmark. `mergeRestoredURL:bookmark:forRestoration:` installs both before publishing and persists only on a path or bookmark change. A failed lookup leaves the grant active and exact.
- *`~/Music`:* one operation on `_restorationQueue`, enqueued ahead of the stored restorations, reads the real home's volume. On main it sets `musicFoldsCase` and, on a change, posts the coalesced `FolderAccessManagerDidChangeNotification`, which already makes folder art reconsider settled answers. It holds neither the launch completion nor its deadline.

## Tests

Host-less, in `Tests/FolderAccessCoverageTests.m`, with injected modes:

- **Rule** (replacing `testReadCoverageFoldsCaseWhereTheAddCheckDoesNot` and `testReadCoverageStillRejectsASibling`): exact mode rejects a case variant, folded mode accepts it, both reject `AlbumsOld` and keep `/private` and firmlink equivalence.
- **Manager**, via `mergeAdditions:`: a case-sensitive grant covers `Albums/Disc 1` and not `albums/Disc 1`; a folded one covers both; no mode means exact; an inactive stored row covers nothing.
- **Restoration**, with a mode on `BlockingFolderAccessManager`'s fake result: inactive before settling, atomic with the path, exact when missing, gone on removal, and a racing reactivation keeps the new grant's mode.
- **Persistence:** a folded grant's stored row holds only `path` and `bookmark`; a fresh manager authorizes nothing before restoration.

**Manual**, on a temporary case-sensitive APFS disk image: sibling `Albums` and `albums`, each with a track and a cover; grant only `Albums`. Its track shows the cover and the `albums` track does not; granting `albums` brings its cover; both restore after relaunch. On the startup volume, a differently-cased spelling of a granted folder is still covered.

## Docs to update

- `Vibe/Mac/App/CLAUDE.md`: the "coverage has two spellings" trap becomes the three-question split.
- `Vibe/Mac/App/FolderAccessManager.h`: drop `+readablePath:isCoveredByAnyOf:`; the read test follows each root's volume.
- `Vibe/Mac/App/FolderAccessRules.h`: the folding rule's `TRAP:` names restoration matching and a case-insensitive root as its only uses.

## Non-goals

Canonicalizing track or playlist URLs; symlink resolution or parent walks during authorization; changing the bookmark store, the deadline, worker allocation, folder-art policy, or iOS; any UI.

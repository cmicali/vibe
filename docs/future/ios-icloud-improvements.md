# iCloud Drive on iOS: browser follow-ups

**Status: Partly built.** The folder setup and cached artwork for files not downloaded are built. Add Folder… is documented in `Vibe/iOS/AGENTS.md`, and `loadCachedMetadata:` in `Vibe/Audio/Metadata/AGENTS.md`. What remains is one device check and the browser follow-ups below.

## Device check

On a real device, check that an iCloud eviction keeps the file's size and modification date. The metadata cache key reads both, so a changed attribute turns a cached thumbnail into a miss. The simulator's fake cloud provider proved the rest.

## Browser follow-ups

These apply to local folders, Dropbox and granted provider folders alike. Each needs a product decision before code. Their regression cases are in [the shell test plan](ios-shell-unit-tests.md#browser-regression-cases).

| Follow-up | Today, and the decision needed |
| --- | --- |
| Empty folder Add or Play | Adding a folder that holds only subfolders adds nothing. A nonrecursive Play can land nothing silently. Play and Add with Subfolders exist, bounded at 2,000 songs or 500 folders. Decide how an empty result explains or offers that action, without making an ordinary folder action recurse. |
| Duplicate additions | Files already in the playlist are skipped with no message and no row mark. Decide how an all-duplicate Add differs from an empty folder, and whether rows show playlist membership. |
| Download-progress legibility | The card draws transfer progress along the waveform line. Whether it reads well during a slow transfer is unknown. Measure on a constrained link before changing it. |
| Add feedback outside Files | Files rows animate when added. Recents and Search adds do not. iPad rows fade in place. Decide whether those need confirmation, including empty and duplicate results. |
| Replace confirmation | The Replace / Add Instead / Cancel guard for a hand-built playlist stays unless the product decision changes. |
| Older Recents names | New records save their folder's display name. Older records derive it from the stored path and can show an old container or account name. Decide whether to migrate or improve the fallback, without a fresh grant or a remote lookup just to draw a row. |

iPad, Dynamic Type, VoiceOver, offline and error paths, the system pickers, Location removal and slow transfers were never audited. Check the affected cases when building a follow-up.

## Verification

- Exercise an empty folder, a folder of subfolders, an all-duplicate Add and a mixed selection in Files, Recents and Search.
- Check a hand-built and a restored playlist, older Recents records and slow transfers as relevant.
- Keep each follow-up in the existing browser, session and presentation owners: zero new files and zero new types.
